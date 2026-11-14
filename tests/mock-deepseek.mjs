// Minimal OpenAI/DeepSeek-compatible chat completions server used by the
// rootfs tests: streams a fixed reply as SSE so the guest's undici fetch path
// (WebAssembly-less llhttp polyfill) is exercised end to end.
//
// Usage: node tests/mock-deepseek.mjs [port]   (default 3199)
import http from 'node:http';

const port = Number(process.argv[2] ?? 3199);
const REPLY = 'MOCK-REPLY-7f3a: hello from the mock DeepSeek server';
// With --tool <name>, the first completion asks for that tool and the second
// reports what came back, so a whole tool round trip can be tested headlessly.
// --tool-args '<json>' supplies its arguments (default '{}').
const toolFlag = process.argv.indexOf('--tool');
const TOOL = toolFlag > 0 ? process.argv[toolFlag + 1] : null;
// Tools with required parameters (health_query's `metric`) need real arguments.
const argsFlag = process.argv.indexOf('--tool-args');
const TOOL_ARGS = argsFlag > 0 ? process.argv[argsFlag + 1] : '{}';


const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.method === 'GET' && req.url.endsWith('/models')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ object: 'list', data: [{ id: 'deepseek-chat', object: 'model' }] }));
      return;
    }
    if (req.method === 'POST' && /\/messages(\?|$)/.test(req.url)) {
      messagesApi(req, res, body);
      return;
    }
    if (req.method !== 'POST' || !req.url.includes('/chat/completions')) {
      res.writeHead(404); res.end('not found'); return;
    }
    let payload = {};
    try { payload = JSON.parse(body || '{}'); } catch { /* ignore */ }
    const id = 'chatcmpl-mock';
    const model = payload.model ?? 'deepseek-chat';
    const chunk = (delta, finish = null) => `data: ${JSON.stringify({
      id, object: 'chat.completion.chunk', created: 1700000000, model,
      choices: [{ index: 0, delta, finish_reason: finish }],
    })}\n\n`;

    // Tool mode: first turn asks for the tool, later turns quote its result.
    if (TOOL) {
      const messages = payload.messages ?? [];
      console.log('[mock] tools offered:', (payload.tools ?? []).map((t) => t.function?.name ?? t.name).join(', ') || '(none)');
      const lastTool = [...messages].reverse().find((m) => m.role === 'tool');
      if (lastTool) console.log('[mock] tool message:', JSON.stringify(lastTool).slice(0, 400));
      const toolResult = [...messages].reverse().find((m) => m.role === 'tool');
      const offers = (payload.tools ?? []).some((t) => (t.function?.name ?? t.name) === TOOL);
      // Ask for the tool until its result comes back in the conversation, so
      // repeated runs against one mock process behave identically.
      if (!toolResult && offers) {
        const call = { index: 0, id: 'call_mock_1', type: 'function', function: { name: TOOL, arguments: TOOL_ARGS } };
        res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
        res.write(chunk({ role: 'assistant', content: '', tool_calls: [call] }));
        res.write(chunk({}, 'tool_calls'));
        res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1700000000, model, choices: [], usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 } })}\n\n`);
        res.write('data: [DONE]\n\n');
        res.end();
        return;
      }
      const observed = typeof toolResult?.content === 'string' ? toolResult.content : JSON.stringify(toolResult?.content ?? {});
      const text = `TOOL-RESULT-BEGIN ${observed.slice(0, 800)} TOOL-RESULT-END`;
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      res.write(chunk({ role: 'assistant', content: '' }));
      for (const word of text.split(' ')) res.write(chunk({ content: word + ' ' }));
      res.write(chunk({}, 'stop'));
      res.write('data: [DONE]\n\n');
      res.end();
      return;
    }

    if (payload.stream === false) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        id, object: 'chat.completion', created: 1700000000, model,
        choices: [{ index: 0, message: { role: 'assistant', content: REPLY }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 10, completion_tokens: 12, total_tokens: 22 },
      }));
      return;
    }
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    });
    res.write(chunk({ role: 'assistant', content: '' }));
    const words = REPLY.split(' ');
    let i = 0;
    const timer = setInterval(() => {
      if (i < words.length) {
        res.write(chunk({ content: (i ? ' ' : '') + words[i++] }));
      } else {
        clearInterval(timer);
        res.write(chunk({}, 'stop'));
        res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1700000000, model, choices: [], usage: { prompt_tokens: 10, completion_tokens: 12, total_tokens: 22 } })}\n\n`);
        res.write('data: [DONE]\n\n');
        res.end();
      }
    }, 20);
  });
});

// DeepSeek's Messages API (Anthropic wire format, `POST <base>/v1/messages`),
// which dsh 0.2 uses instead of chat completions. Same behaviour as above:
// a fixed reply, or in tool mode a tool call followed by a quote of its result.
function messagesApi(req, res, body) {
  let payload = {};
  try { payload = JSON.parse(body || '{}'); } catch { /* ignore */ }
  const model = payload.model ?? 'deepseek-chat';
  const messages = payload.messages ?? [];
  const blocks = (m) => (Array.isArray(m.content) ? m.content : []);
  const toolResult = [...messages].reverse().flatMap((m) => blocks(m).filter((b) => b.type === 'tool_result'))[0];
  const offers = (payload.tools ?? []).some((t) => t.name === TOOL);
  let content; let stop;
  if (TOOL) console.log('[mock] tools offered:', (payload.tools ?? []).map((t) => t.name).join(', ') || '(none)');
  if (TOOL && !toolResult && offers) {
    content = { type: 'tool_use', id: 'toolu_mock_1', name: TOOL, input: {} };
    stop = 'tool_use';
  } else if (TOOL && toolResult) {
    const raw = toolResult.content;
    const observed = typeof raw === 'string' ? raw
      : Array.isArray(raw) ? raw.map((b) => b.text ?? JSON.stringify(b)).join('\n') : JSON.stringify(raw ?? {});
    console.log('[mock] tool result:', observed.slice(0, 400));
    content = { type: 'text', text: `TOOL-RESULT-BEGIN ${observed.slice(0, 800)} TOOL-RESULT-END` };
    stop = 'end_turn';
  } else {
    content = { type: 'text', text: REPLY };
    stop = 'end_turn';
  }
  const message = { id: 'msg_mock', type: 'message', role: 'assistant', model, stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } };
  if (payload.stream !== true) {
    const final = content.type === 'tool_use' ? { ...content, input: JSON.parse(TOOL_ARGS) } : content;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ...message, content: [final], stop_reason: stop, usage: { input_tokens: 10, output_tokens: 12 } }));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
  const send = (data) => res.write(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);
  send({ type: 'message_start', message: { ...message, content: [] } });
  if (content.type === 'tool_use') {
    send({ type: 'content_block_start', index: 0, content_block: content });
    send({ type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: TOOL_ARGS } });
  } else {
    send({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
    for (const word of content.text.split(' ')) send({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: word + ' ' } });
  }
  send({ type: 'content_block_stop', index: 0 });
  send({ type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 12 } });
  send({ type: 'message_stop' });
  res.end();
}

// Bind all interfaces when asked (--lan), so a device on the same network can
// reach it for on-device end-to-end tests; loopback only by default.
const host = process.argv.includes('--lan') ? '0.0.0.0' : '127.0.0.1';
server.listen(port, host, () => {
  console.log(`mock-deepseek listening on http://${host}:${port}`);
});

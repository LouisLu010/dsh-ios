// A minimal third-party dsh plugin: one tool with a fixed answer, so a test
// can tell that a package installed with `dsh plugin add` was mounted and
// reached the model.
import { defineTool } from "@deepseek-ai/dsh-tools";

export const name = "plugin-fixture";
export const inject = ["tools"];

export function apply(ctx) {
  ctx.tools.register(defineTool({
    name: "fixture_ping",
    description: "Test fixture: answers with a fixed marker string.",
    parameters: {},
    output: {
      schema: {
        type: "object",
        additionalProperties: false,
        properties: { marker: { type: "string" } },
      },
      render: (_args, value) => [{ type: "text", text: value.marker }],
    },
    execute: async () => ({ marker: "FIXTURE-PONG-41c9" }),
    presentCall: () => ({ card: "generic", title: "Fixture ping", kind: "other" }),
  }));
}

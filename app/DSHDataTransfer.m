//
//  DSHDataTransfer.m
//  DSH
//

#import "DSHDataTransfer.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static NSString *const kDoneMarker = @"DSH-TRANSFER-DONE";
static NSString *const kErrorPrefix = @"DSH-TRANSFER-ERROR: ";

#pragma mark - Document picker callbacks as blocks

@interface DSHTransferPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) void (^picked)(NSURL *url);
@property (nonatomic, copy, nullable) void (^finished)(void);
@end

@implementation DSHTransferPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.picked && urls.firstObject) self.picked(urls.firstObject);
    if (self.finished) self.finished();
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.finished) self.finished();
}

@end

static void DSHAttachDelegate(UIDocumentPickerViewController *picker, DSHTransferPickerDelegate *delegate) {
    // UIDocumentPickerViewController holds its delegate weakly.
    picker.delegate = delegate;
    objc_setAssociatedObject(picker, @selector(delegate), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Helpers

/// Single-quotes a value for /bin/sh.
static NSString *DSHShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

/// A fresh host directory in the app's temporary folder, plus the guest mount
/// point it will appear at.
static NSURL *DSHMakeTransferDirectory(NSString **mountPoint) {
    NSString *token = [[NSUUID UUID].UUIDString substringToIndex:8].lowercaseString;
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                  URLByAppendingPathComponent:[@"dsh-transfer-" stringByAppendingString:token] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    *mountPoint = [@"/mnt/dsh-transfer-" stringByAppendingString:token];
    return dir;
}

/// Script prologue: mount the host directory in the guest and always unmount it.
static NSString *DSHMountPrologue(NSURL *hostDir, NSString *mountPoint, NSString *extraCleanup) {
    return [NSString stringWithFormat:
        @"set -e\n"
        @"T=%@\n"
        @"mkdir -p \"$T\"\n"
        @"mount -t real %@ \"$T\"\n"
        @"cleanup() { cd /; %@ umount \"$T\" 2>/dev/null; rmdir \"$T\" 2>/dev/null; true; }\n"
        @"trap cleanup EXIT\n"
        @"fail() { echo \"%@$1\"; exit 2; }\n",
        DSHShellQuote(mountPoint), DSHShellQuote(hostDir.path), extraCleanup, kErrorPrefix];
}

static UIAlertController *DSHShowProgress(UIViewController *presenter, NSString *title) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"This can take a while for a large workspace. Keep DeepSeek Harness open."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:alert animated:YES completion:nil];
    return alert;
}

static void DSHShowMessage(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

/// Runs a guest script, collecting the error line it prints on failure.
static void DSHRunGuestScript(NSString *label, NSString *script, void (^completion)(BOOL ok, NSString *_Nullable error)) {
    DSHLogBuffer *log = DSHHarness.shared.log;
    __block BOOL sawDone = NO;
    __block NSString *failure = nil;
    [ISHShellExecutor executeCommand:script lineCallback:^(NSString *line, BOOL isStdErr) {
        if ([line containsString:kDoneMarker]) sawDone = YES;
        else if ([line hasPrefix:kErrorPrefix]) failure = [line substringFromIndex:kErrorPrefix.length];
        [log append:[NSString stringWithFormat:@"[dsh-ios] %@: %@", label, line]];
    } completion:^(ISHShellExecutionResult *result) {
        BOOL ok = result.exitCode == 0 && sawDone;
        if (!ok && failure == nil)
            failure = [NSString stringWithFormat:@"The Linux command failed (exit %d). Details are in ⋯ ▸ Server Log.", result.exitCode];
        completion(ok, ok ? nil : failure);
    }];
}

#pragma mark - Export

@implementation DSHDataTransfer

+ (void)exportFromViewController:(UIViewController *)presenter {
    NSString *mountPoint = nil;
    NSURL *hostDir = DSHMakeTransferDirectory(&mountPoint);
    NSString *appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";

    NSString *script = [DSHMountPrologue(hostDir, mountPoint, @"rm -f /root/dsh-backup.json;") stringByAppendingFormat:
        @"cd /root\n"
        @"[ -d .dsh ] || fail 'there is no harness data to export yet'\n"
        @"v=$(node -p \"require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').version\" 2>/dev/null || echo unknown)\n"
        @"printf '{\"format\":1,\"app\":\"%%s\",\"dsh\":\"%%s\",\"created\":\"%%s\"}\\n' %@ \"$v\" \"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\" > dsh-backup.json\n"
        @"set -- dsh-backup.json .dsh\n"
        @"[ -d workspace ] && set -- \"$@\" workspace\n"
        @"tar czf \"$T/backup.tar.gz\" \"$@\" || fail 'tar could not write the archive'\n"
        @"echo %@\n",
        DSHShellQuote(appVersion), kDoneMarker];

    UIAlertController *progress = DSHShowProgress(presenter, @"Exporting data…");
    DSHRunGuestScript(@"export", script, ^(BOOL ok, NSString *error) {
        [progress dismissViewControllerAnimated:YES completion:^{
            NSURL *archive = [hostDir URLByAppendingPathComponent:@"backup.tar.gz"];
            if (!ok || ![NSFileManager.defaultManager fileExistsAtPath:archive.path]) {
                [NSFileManager.defaultManager removeItemAtURL:hostDir error:nil];
                DSHShowMessage(presenter, @"Export failed", error ?: @"The archive was not created.");
                return;
            }
            NSDateFormatter *format = [NSDateFormatter new];
            format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            format.dateFormat = @"yyyyMMdd-HHmm";
            NSURL *named = [hostDir URLByAppendingPathComponent:
                            [NSString stringWithFormat:@"DeepSeek-Harness-backup-%@.tar.gz", [format stringFromDate:NSDate.date]]];
            [NSFileManager.defaultManager moveItemAtURL:archive toURL:named error:nil];

            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[named] asCopy:YES];
            DSHTransferPickerDelegate *delegate = [DSHTransferPickerDelegate new];
            delegate.finished = ^{ [NSFileManager.defaultManager removeItemAtURL:hostDir error:nil]; };
            DSHAttachDelegate(picker, delegate);
            [presenter presentViewController:picker animated:YES completion:nil];
        }];
    });
}

#pragma mark - Import

+ (void)importFromViewController:(UIViewController *)presenter {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection = NO;
    DSHTransferPickerDelegate *delegate = [DSHTransferPickerDelegate new];
    delegate.picked = ^(NSURL *url) {
        // Let the picker finish dismissing before the next alert.
        dispatch_async(dispatch_get_main_queue(), ^{ [self confirmImportOf:url from:presenter]; });
    };
    DSHAttachDelegate(picker, delegate);
    [presenter presentViewController:picker animated:YES completion:nil];
}

+ (void)confirmImportOf:(NSURL *)url from:(UIViewController *)presenter {
    NSString *message = [NSString stringWithFormat:
        @"“%@” will replace your sessions, credentials (API keys), settings, plugins and workspace. "
        @"The harness restarts afterwards.\n\nYour current data is kept in /root/.dsh.before-import and "
        @"/root/workspace.before-import until the next import.", url.lastPathComponent];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import data?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Replace and Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self importArchive:url from:presenter];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)importArchive:(NSURL *)url from:(UIViewController *)presenter {
    NSString *mountPoint = nil;
    NSURL *hostDir = DSHMakeTransferDirectory(&mountPoint);
    NSError *copyError = nil;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    BOOL copied = [NSFileManager.defaultManager copyItemAtURL:url toURL:[hostDir URLByAppendingPathComponent:@"import.tar.gz"] error:&copyError];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!copied) {
        [NSFileManager.defaultManager removeItemAtURL:hostDir error:nil];
        DSHShowMessage(presenter, @"Import failed", [NSString stringWithFormat:@"Could not read the file: %@", copyError.localizedDescription]);
        return;
    }

    // Everything is checked before anything is moved, so a bad archive leaves
    // the current data as it was. Entries may only be dsh-backup.json, .dsh/…
    // and workspace/…, with no "..". (The archive is extracted inside the
    // guest, which the user and the agent already control completely.)
    NSString *script = [DSHMountPrologue(hostDir, mountPoint, @"rm -rf /tmp/dsh-import /tmp/dsh-import.list;") stringByAppendingFormat:
        @"A=\"$T/import.tar.gz\"\n"
        @"L=/tmp/dsh-import.list\n"
        @"S=/tmp/dsh-import\n"
        @"tar tzf \"$A\" > \"$L\" 2>/dev/null || fail 'the file is not a .tar.gz archive'\n"
        @"sed -i 's#^\\./##; /^\\.\\{0,1\\}$/d' \"$L\"\n"
        @"grep -qx 'dsh-backup.json' \"$L\" || fail 'the archive is not a DeepSeek Harness backup (no dsh-backup.json)'\n"
        @"grep -q '^\\.dsh/' \"$L\" || fail 'the archive contains no .dsh directory'\n"
        @"if grep -Ev '^(dsh-backup\\.json|\\.dsh(/.*)?|workspace(/.*)?)$' \"$L\" | grep -q .; then fail 'the archive contains files outside .dsh and workspace'; fi\n"
        @"if grep -Eq '(^|/)\\.\\.(/|$)' \"$L\"; then fail 'the archive contains .. path components'; fi\n"
        @"rm -rf \"$S\" && mkdir -p \"$S\"\n"
        @"tar xzf \"$A\" -C \"$S\" || fail 'the archive could not be extracted'\n"
        @"cd /root\n"
        @"rm -rf .dsh.before-import workspace.before-import\n"
        @"[ -e .dsh ] && mv .dsh .dsh.before-import\n"
        @"if ! mv \"$S/.dsh\" .dsh; then [ -e .dsh.before-import ] && mv .dsh.before-import .dsh; fail 'could not move the imported data into place'; fi\n"
        @"if [ -d \"$S/workspace\" ]; then\n"
        @"  [ -e workspace ] && mv workspace workspace.before-import\n"
        @"  mv \"$S/workspace\" workspace\n"
        @"fi\n"
        @"mkdir -p workspace\n"
        @"echo %@\n",
        kDoneMarker];

    UIAlertController *progress = DSHShowProgress(presenter, @"Importing data…");
    DSHHarness *harness = DSHHarness.shared;
    [harness.log append:@"[dsh-ios] import: stopping the harness"];
    [harness stop];
    // Give dsh a moment to exit before its home directory is swapped.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSHRunGuestScript(@"import", script, ^(BOOL ok, NSString *error) {
            [NSFileManager.defaultManager removeItemAtURL:hostDir error:nil];
            // Back on the imported data, or on the untouched old data after a failure.
            [harness start];
            [progress dismissViewControllerAnimated:YES completion:^{
                if (ok)
                    DSHShowMessage(presenter, @"Import complete", @"The harness is restarting on the imported data.");
                else
                    DSHShowMessage(presenter, @"Import failed", [error stringByAppendingString:
                        @"\n\nThe archive is checked before anything is replaced, so your data is normally unchanged. "
                        @"If the import stopped part-way, the previous data is in /root/.dsh.before-import."]);
            }];
        });
    });
}

@end

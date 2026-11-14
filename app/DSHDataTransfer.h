//
//  DSHDataTransfer.h
//  DSH
//
//  Export and import of the user's data as one .tar.gz archive:
//    .dsh/            harness home: sessions, credentials (API keys), settings,
//                     the user's patch layers and the plugins in each profile
//    workspace/       /root/workspace
//    dsh-backup.json  format marker, app and dsh versions, creation time
//
//  The archive moves between iOS and the guest through a host directory in
//  the app's temporary folder, mounted in the guest with `mount -t real`.
//
//  Import replaces .dsh and workspace. The previous copies are kept as
//  /root/.dsh.before-import and /root/workspace.before-import until the next
//  import, and the harness is restarted on the imported data.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHDataTransfer : NSObject

/// Builds the archive and offers it to the system "save to Files" sheet.
+ (void)exportFromViewController:(UIViewController *)presenter;

/// Asks for an archive, confirms, and replaces the current data with it.
+ (void)importFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END

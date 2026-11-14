//
//  DSHBackgroundKeepAlive.h
//  DSH
//
//  iOS suspends an app that leaves the screen, and the whole Linux guest is
//  threads inside this process, so the harness stops with it. The one
//  general-purpose way iOS lets an app keep running in the background is
//  continuous location updates (UIBackgroundModes = location). This turns that
//  on as an opt-in setting, so a long agent turn keeps going while the user is
//  in another app.
//
//  What it does and does not do:
//    - Off by default. The user switches it on in ⋯ ▸ Keep Running in Background.
//    - Asks for "While Using" location access the first time; that is enough,
//      because updates are started while the app is on screen.
//    - Uses the coarsest accuracy and ignores every reading. Nothing is
//      stored, logged or given to the agent; location_query is unaffected.
//    - iOS shows the blue location indicator while the app runs in the
//      background, so the user can always see that it is on.
//    - Costs battery. It is a sideloading feature: App Store review does not
//      accept background location used only to stay awake.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSHKeepAliveState) {
    DSHKeepAliveStateOff,
    /// Switched on, waiting for the user to answer the location prompt.
    DSHKeepAliveStateWaitingForPermission,
    /// Location updates are running; the app keeps running in the background.
    DSHKeepAliveStateActive,
    /// Switched on, but location access is denied or restricted.
    DSHKeepAliveStateDenied,
};

/// Posted on the main thread whenever `state` changes.
extern NSNotificationName const DSHKeepAliveStateDidChangeNotification;

@interface DSHBackgroundKeepAlive : NSObject

@property (class, nonatomic, readonly) DSHBackgroundKeepAlive *shared;

/// The user's choice, persisted across launches. Setting it starts or stops
/// the location updates (asking for permission if needed). Main thread only.
@property (nonatomic, getter=isEnabled) BOOL enabled;

@property (nonatomic, readonly) DSHKeepAliveState state;

/// Whether the app is currently being kept alive.
@property (nonatomic, readonly, getter=isActive) BOOL active;

/// Resumes the saved setting at launch. Safe to call more than once.
- (void)start;

@end

NS_ASSUME_NONNULL_END

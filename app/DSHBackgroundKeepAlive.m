//
//  DSHBackgroundKeepAlive.m
//  DSH
//

#import "DSHBackgroundKeepAlive.h"
#import "DSHHarness.h"
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

NSNotificationName const DSHKeepAliveStateDidChangeNotification = @"DSHKeepAliveStateDidChange";
static NSString *const kEnabledKey = @"DSHKeepAliveInBackground";

@interface DSHBackgroundKeepAlive () <CLLocationManagerDelegate>
@property (nonatomic, readwrite) DSHKeepAliveState state;
@end

@implementation DSHBackgroundKeepAlive {
    CLLocationManager *_manager;
    BOOL _started;
    BOOL _updating;
}

+ (DSHBackgroundKeepAlive *)shared {
    static DSHBackgroundKeepAlive *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DSHBackgroundKeepAlive new]; });
    return shared;
}

- (BOOL)isEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey];
}

- (void)setEnabled:(BOOL)enabled {
    NSAssert(NSThread.isMainThread, @"keep-alive on main");
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabledKey];
    [DSHHarness.shared.log append:enabled ? @"[dsh-ios] keep running in background: on"
                                          : @"[dsh-ios] keep running in background: off"];
    [self apply];
}

- (BOOL)isActive {
    return self.state == DSHKeepAliveStateActive;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"keep-alive on main");
    if (_started) return;
    _started = YES;
    // Location updates that keep a When-In-Use app alive have to be started
    // while it is on screen, so (re)apply every time the app becomes active.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(apply)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];
    [self apply];
}

- (CLLocationManager *)manager {
    if (_manager == nil) {
        _manager = [CLLocationManager new];
        _manager.delegate = self;
        // The readings are thrown away; ask for the cheapest ones there are.
        _manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
        _manager.distanceFilter = CLLocationDistanceMax;
        _manager.activityType = CLActivityTypeOther;
        _manager.pausesLocationUpdatesAutomatically = NO;
        _manager.showsBackgroundLocationIndicator = YES;
    }
    return _manager;
}

- (void)apply {
    if (!self.isEnabled) {
        [self stopUpdates];
        self.state = DSHKeepAliveStateOff;
        return;
    }
    CLLocationManager *manager = self.manager;
    switch (manager.authorizationStatus) {
        case kCLAuthorizationStatusNotDetermined:
            self.state = DSHKeepAliveStateWaitingForPermission;
            [manager requestWhenInUseAuthorization];   // answered in the delegate
            break;
        case kCLAuthorizationStatusDenied:
        case kCLAuthorizationStatusRestricted:
            [self stopUpdates];
            self.state = DSHKeepAliveStateDenied;
            break;
        default:
            [self startUpdates];
            self.state = DSHKeepAliveStateActive;
            break;
    }
}

- (void)startUpdates {
    if (_updating) return;
    // Background updates need UIBackgroundModes = location in Info.plist;
    // without it this property throws, so check rather than crash a build
    // that dropped the key.
    NSArray *modes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    if (![modes containsObject:@"location"]) {
        [DSHHarness.shared.log append:@"[dsh-ios] keep-alive unavailable: Info.plist has no location background mode"];
        return;
    }
    self.manager.allowsBackgroundLocationUpdates = YES;
    [self.manager startUpdatingLocation];
    _updating = YES;
}

- (void)stopUpdates {
    if (!_updating) return;
    [_manager stopUpdatingLocation];
    _manager.allowsBackgroundLocationUpdates = NO;
    _updating = NO;
}

- (void)setState:(DSHKeepAliveState)state {
    if (_state == state) return;
    _state = state;
    [NSNotificationCenter.defaultCenter postNotificationName:DSHKeepAliveStateDidChangeNotification object:self];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self apply];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    // Deliberately ignored: the updates exist only to keep the process running.
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // kCLErrorLocationUnknown is transient and the updates keep running.
    if (error.code == kCLErrorDenied) {
        [self stopUpdates];
        self.state = DSHKeepAliveStateDenied;
    }
}

@end

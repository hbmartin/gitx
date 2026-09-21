#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBAutoFetchManager interface.
/// App-hosted Objective-C tests cannot directly import the app target's generated header.
@interface PBAutoFetchManager : NSObject <UNUserNotificationCenterDelegate>
+ (instancetype)sharedManager;
+ (NSTimeInterval)retryDelayForFailureCount:(NSUInteger)failureCount;
- (void)start;
- (void)stop;
- (void)stopForApplicationTermination;
- (void)recordManualFetchSucceededForRepositoryURL:(NSURL *)repositoryURL;
@end

NS_ASSUME_NONNULL_END

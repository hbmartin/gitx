#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Coordinates unattended remote refreshes for the repositories selected by
/// the global auto-fetch preference. Failures retry with bounded exponential
/// backoff independently for each repository.
@interface PBAutoFetchManager : NSObject

+ (instancetype)sharedManager;
- (void)start;
/// Invalidates the polling timer and drops the notification and workspace
/// observers installed by `start`. Without this the manager keeps fetching every
/// recent repository for as long as the process lives, even with no window open.
/// Safe to call when not started, and `start` may be called again afterwards.
- (void)stop;
- (void)recordManualFetchSucceededForRepositoryURL:(NSURL *)repositoryURL;

@end

NS_ASSUME_NONNULL_END

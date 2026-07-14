#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Coordinates unattended remote refreshes for the repositories selected by
/// the global auto-fetch preference. Failures retry with bounded exponential
/// backoff independently for each repository.
@interface PBAutoFetchManager : NSObject

+ (instancetype)sharedManager;
- (void)start;
- (void)recordManualFetchSucceededForRepositoryURL:(NSURL *)repositoryURL;

@end

NS_ASSUME_NONNULL_END

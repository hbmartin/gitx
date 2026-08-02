#import "PBNativeContentView.h"
#import "PBWebController.h"

@class PBGitCommit;

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBWebHistoryController interface.
/// App-hosted Objective-C tests use this declaration without importing the
/// complete generated header, while production owns the runtime class.
@interface PBWebHistoryController : PBWebController <PBNativeContentViewDelegate>

@property (readonly, nullable) NSString *diff;

- (void)sendKey:(NSString *)key;
- (void)scrollPageUp;
- (void)scrollPageDown;
- (void)refreshDisplayedContent;
- (NSUInteger)beginContentGeneration;
- (NSArray<NSDictionary<NSString *, id> *> *)sections:(NSArray<NSDictionary<NSString *, id> *> *)sections
										  applyingDiffLayout:(NSInteger)layout;

@end

NS_ASSUME_NONNULL_END

#import "PBGitTree.h"

@class PBGitRepository;

NS_ASSUME_NONNULL_BEGIN

/// A tree assembled from the non-ignored checkout rather than a commit tree.
@interface PBWorkingTree : PBGitTree
+ (instancetype)rootForRepository:(PBGitRepository *)repository;
@property (nonatomic, readonly) NSString *displayPath;
@property (nonatomic, readonly, nullable) NSString *workingStatus;
@end

NS_ASSUME_NONNULL_END

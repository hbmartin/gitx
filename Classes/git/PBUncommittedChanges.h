#import "PBGitCommit.h"

@class PBGitRepository;

NS_ASSUME_NONNULL_BEGIN

/// PBGitCommit-compatible row model for the repository's mutable Working State.
@interface PBUncommittedChanges : PBGitCommit
- (instancetype)initWithRepository:(PBGitRepository *)repository;
@property (nonatomic, readonly) NSUInteger stagedCount;
@property (nonatomic, readonly) NSUInteger unstagedCount;
@property (nonatomic, readonly) NSUInteger untrackedCount;
@property (nonatomic, readonly) BOOL isWorkingState;
@end

NS_ASSUME_NONNULL_END

#import "PBUncommittedChanges.h"
#import "PBWorkingTree.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"

@interface PBUncommittedChanges ()
@property (nonatomic, weak) PBGitRepository *workingRepository;
@property (nonatomic) NSUInteger stagedCount;
@property (nonatomic) NSUInteger unstagedCount;
@property (nonatomic) NSUInteger untrackedCount;
@property (nonatomic) PBGitTree *workingTree;
@end

@implementation PBUncommittedChanges

- (instancetype)initWithRepository:(PBGitRepository *)repository
{
	self = [super init];
	if (!self) return nil;
	_workingRepository = repository;
	[self refreshFromRepository];
	return self;
}

- (void)refreshFromRepository
{
	NSUInteger stagedCount = 0;
	NSUInteger unstagedCount = 0;
	NSUInteger untrackedCount = 0;
	for (PBChangedFile *file in self.workingRepository.index.indexChanges) {
		if (file.hasStagedChanges) stagedCount++;
		if (file.hasUnstagedChanges && file.status != NEW) unstagedCount++;
		if (file.hasUnstagedChanges && file.status == NEW) untrackedCount++;
	}
	self.stagedCount = stagedCount;
	self.unstagedCount = unstagedCount;
	self.untrackedCount = untrackedCount;
	self.workingTree = nil;
}

- (BOOL)isWorkingState
{
	return YES;
}
- (PBGitRepository *)repository
{
	return self.workingRepository;
}
- (NSString *)subject
{
	NSString *format = NSLocalizedString(@"%lu staged, %lu unstaged, %lu untracked",
										 @"Working-state summary: staged, unstaged, and untracked file counts");
	return [NSString stringWithFormat:format,
									  (unsigned long)self.stagedCount, (unsigned long)self.unstagedCount, (unsigned long)self.untrackedCount];
}
- (NSString *)message
{
	return self.subject;
}
- (NSString *)details
{
	return self.subject;
}
- (NSString *)author
{
	return @"";
}
- (NSString *)authorEmail
{
	return @"";
}
- (NSString *)authorDate
{
	return @"";
}
- (NSString *)committer
{
	return @"";
}
- (NSString *)committerEmail
{
	return @"";
}
- (NSString *)committerDate
{
	return @"";
}
- (NSString *)SHA
{
	return @"";
}
- (NSString *)shortName
{
	return @"";
}
- (NSString *)SVNRevision
{
	return nil;
}
- (NSDate *)date
{
	return [super date];
}
- (GTOID *)OID
{
	return [super OID];
}
- (GTCommit *)gtCommit
{
	return [super gtCommit];
}
- (NSArray<GTOID *> *)parents
{
	return @[];
}
- (NSMutableArray *)refs
{
	return [NSMutableArray array];
}
- (PBGraphCellInfo *)lineInfo
{
	return [super lineInfo];
}
- (PBGitTree *)tree
{
	if (!self.workingTree) self.workingTree = [PBWorkingTree rootForRepository:self.workingRepository];
	return self.workingTree;
}
- (NSArray *)treeContents
{
	return self.tree.children;
}
- (BOOL)isOnHeadBranch
{
	return NO;
}
- (NSString *)refishName
{
	return @"WORKING_STATE";
}
- (NSString *)refishType
{
	return @"working-state";
}

- (NSString *)patch
{
	NSError *error = nil;
	NSString *staged = [self.workingRepository outputOfTaskWithArguments:@[ @"diff", @"--cached", @"--no-ext-diff" ] error:&error] ?: @"";
	NSString *unstaged = [self.workingRepository outputOfTaskWithArguments:@[ @"diff", @"--no-ext-diff" ] error:&error] ?: @"";
	return [NSString stringWithFormat:@"%@%@%@", staged, staged.length && unstaged.length ? @"\n" : @"", unstaged];
}

@end

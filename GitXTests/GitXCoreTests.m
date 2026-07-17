#import <XCTest/XCTest.h>
#import <ObjectiveGit/GTCommit.h>
#import <ObjectiveGit/GTOID.h>
#import <ObjectiveGit/GTRepository.h>
#import "MAKVONotificationCenter.h"
#import "PBMacros.h"
#import "PBError.h"
#import "PBChangedFile.h"
#import "PBGraphCellInfo.h"
#import "PBGitBinary.h"
#import "PBGitCommit.h"
#import "PBGitGrapher.h"
#import "PBGitHistoryList.h"
#import "PBGitIndex.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitRevSpecifier.h"
#import "PBGitSidebarController.h"
#import "PBGitStash.h"
#import "PBNativeContentView.h"
#import "PBSourceViewItem.h"
#import "PBUncommittedChanges.h"
#import "PBWorkingTree.h"
#import "PBTask.h"

@interface PBNativeContentView (GitXCoreTests)
- (nullable NSString *)patchWithFileHeader:(NSArray<NSString *> *)fileHeader
								 hunkLines:(NSArray<NSString *> *)hunkLines
						   selectedIndexes:(NSIndexSet *)selectedIndexes
								   reverse:(BOOL)reverse;
- (NSString *)pathForDiffHeaderAtIndex:(NSUInteger)headerIndex lines:(NSArray<NSString *> *)lines;
@end

@interface PBGitHistoryList (GitXCoreTests)
- (NSSet<GTOID *> *)baseCommits;
@end

@interface PBGitTree (GitXCoreTests)
- (BOOL)hasBinaryHeader:(nullable NSString *)contents;
- (BOOL)hasBinaryAttributes;
@end

@interface PBGitSidebarController (GitXCoreTests)
- (PBSourceViewItem *)addRevSpec:(PBGitRevSpecifier *)rev;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldEditTableColumn:(nullable NSTableColumn *)tableColumn item:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item;
@end

@interface GitXTestRepository : NSObject

@property (nonatomic, copy, readonly) NSString *path;

- (nullable instancetype)initWithError:(NSError **)error;
- (nullable NSString *)git:(NSArray<NSString *> *)arguments error:(NSError **)error;
- (BOOL)writeText:(NSString *)text toPath:(NSString *)relativePath error:(NSError **)error;
- (BOOL)commitAllWithMessage:(NSString *)message error:(NSError **)error;

@end

@implementation GitXTestRepository

- (nullable instancetype)initWithError:(NSError **)error
{
	self = [super init];
	if (!self) return nil;

	_path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"GitXTests-%@", NSUUID.UUID.UUIDString]];
	if (![[NSFileManager defaultManager] createDirectoryAtPath:_path withIntermediateDirectories:YES attributes:nil error:error])
		return nil;

	if (![self git:@[ @"init", @"--quiet", @"--initial-branch=main" ] error:error] ||
		![self git:@[ @"config", @"user.name", @"GitX Test" ] error:error] ||
		![self git:@[ @"config", @"user.email", @"gitx-tests@example.invalid" ] error:error])
		return nil;

	return self;
}

- (void)dealloc
{
	[[NSFileManager defaultManager] removeItemAtPath:self.path error:nil];
}

- (nullable NSString *)git:(NSArray<NSString *> *)arguments error:(NSError **)error
{
	return [PBTask outputForCommand:PBGitBinary.path arguments:arguments inDirectory:self.path error:error];
}

- (BOOL)writeText:(NSString *)text toPath:(NSString *)relativePath error:(NSError **)error
{
	NSString *absolutePath = [self.path stringByAppendingPathComponent:relativePath];
	NSString *parent = absolutePath.stringByDeletingLastPathComponent;
	if (![[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	return [text writeToFile:absolutePath atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (BOOL)commitAllWithMessage:(NSString *)message error:(NSError **)error
{
	return [self git:@[ @"add", @"--all" ] error:error] != nil &&
		[self git:@[ @"commit", @"--quiet", @"-m", message ]
			error:error] != nil;
}

@end

@interface GitXRepositoryTestCase : XCTestCase

@property (nonatomic, strong) GitXTestRepository *fixture;
@property (nonatomic, strong) PBGitRepository *repository;

- (void)refreshIndexAfterPerforming:(dispatch_block_t)operation;
- (void)waitForHistoryUpdate;
- (nullable PBChangedFile *)changedFileAtPath:(NSString *)path;
- (nullable PBGitTree *)treeAtPath:(NSString *)path inRoot:(PBGitTree *)root;

@end


@implementation GitXRepositoryTestCase

- (void)setUp
{
	[super setUp];
	NSError *error = nil;
	self.fixture = [[GitXTestRepository alloc] initWithError:&error];
	XCTAssertNotNil(self.fixture, @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"first line\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"initial commit" error:&error], @"%@", error);
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);
}

- (void)tearDown
{
	// Successful repository mutations schedule asynchronous revision parsing.
	// Keep the temporary repository alive until that work is fully published so
	// a following test cannot inherit an ObjectiveGit operation with a nil repo.
	if (self.repository != nil) {
		[self waitForHistoryUpdate];
		[self.repository.revisionList cleanup];
	}
	self.repository = nil;
	self.fixture = nil;
	[super tearDown];
}

- (void)refreshIndexAfterPerforming:(dispatch_block_t)operation
{
	XCTestExpectation *expectation = [self expectationWithDescription:@"index refresh finished"];
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexFinishedIndexRefresh
					object:self.repository.index
					 queue:NSOperationQueue.mainQueue
				usingBlock:^(__unused NSNotification *notification) {
					[expectation fulfill];
				}];
	operation();
	[self waitForExpectations:@[ expectation ] timeout:10.0];
	[[NSNotificationCenter defaultCenter] removeObserver:token];
}

- (void)waitForHistoryUpdate
{
	PBGitHistoryList *history = self.repository.revisionList;
	if (!history.isUpdating) return;
	NSPredicate *finished = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return !history.isUpdating;
	}];
	XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:finished object:history];
	[self waitForExpectations:@[ expectation ] timeout:10.0];
}

- (nullable PBChangedFile *)changedFileAtPath:(NSString *)path
{
	for (PBChangedFile *file in self.repository.index.indexChanges) {
		if ([file.path isEqualToString:path])
			return file;
	}
	return nil;
}

- (nullable PBGitTree *)treeAtPath:(NSString *)path inRoot:(PBGitTree *)root
{
	NSMutableArray<PBGitTree *> *pending = [root.children mutableCopy];
	while (pending.count) {
		PBGitTree *candidate = pending.firstObject;
		[pending removeObjectAtIndex:0];
		if ([candidate.fullPath isEqualToString:path]) return candidate;
		[pending addObjectsFromArray:candidate.children];
	}
	return nil;
}

@end


@interface GitXRefAndRevisionTests : XCTestCase
@end

@implementation GitXRefAndRevisionTests

- (void)testRefClassificationAndNames
{
	PBGitRef *branch = [PBGitRef refFromString:@"refs/heads/feature/nested"];
	XCTAssertTrue(branch.isBranch);
	XCTAssertEqualObjects(branch.branchName, @"feature/nested");
	XCTAssertEqualObjects(branch.shortName, @"feature/nested");
	XCTAssertEqualObjects(branch.refishType, kGitXBranchType);

	PBGitRef *tag = [PBGitRef refFromString:@"refs/tags/v1.2.3"];
	XCTAssertTrue(tag.isTag);
	XCTAssertEqualObjects(tag.tagName, @"v1.2.3");
	XCTAssertEqualObjects(tag.refishType, kGitXTagType);

	PBGitRef *remoteBranch = [PBGitRef refFromString:@"refs/remotes/origin/team/topic"];
	XCTAssertTrue(remoteBranch.isRemote);
	XCTAssertTrue(remoteBranch.isRemoteBranch);
	XCTAssertEqualObjects(remoteBranch.remoteName, @"origin");
	XCTAssertEqualObjects(remoteBranch.remoteBranchName, @"team/topic");
	XCTAssertEqualObjects(remoteBranch.remoteRef.ref, @"refs/remotes/origin");
	XCTAssertEqualObjects(remoteBranch.refishType, kGitXRemoteBranchType);

	PBGitRef *stash = [PBGitRef refFromString:@"refs/stash@{2}"];
	XCTAssertTrue(stash.isStash);
	XCTAssertEqualObjects(stash.shortName, @"stash@{2}");
	XCTAssertEqualObjects(stash.refishType, kGitXStashType);
}

- (void)testRefEqualityUsesFullReference
{
	PBGitRef *first = [PBGitRef refFromString:@"refs/heads/main"];
	PBGitRef *same = [PBGitRef refFromString:@"refs/heads/main"];
	PBGitRef *tag = [PBGitRef refFromString:@"refs/tags/main"];
	XCTAssertTrue([first isEqualToRef:same]);
	XCTAssertFalse([first isEqualToRef:tag]);
}

- (void)testRevisionSpecifierDistinguishesSimpleAndComplexRevisions
{
	PBGitRevSpecifier *simple = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"refs/heads/main" ]];
	XCTAssertTrue(simple.isSimpleRef);
	XCTAssertEqualObjects(simple.simpleRef, @"refs/heads/main");
	XCTAssertEqualObjects(simple.ref.ref, @"refs/heads/main");
	XCTAssertFalse(simple.hasPathLimiter);

	NSArray<NSString *> *complexValues = @[ @"HEAD~2", @"main..topic", @"branch@{upstream}", @"-invalid", @"name with space" ];
	for (NSString *value in complexValues) {
		PBGitRevSpecifier *complex = [[PBGitRevSpecifier alloc] initWithParameters:@[ value ]];
		XCTAssertFalse(complex.isSimpleRef, @"%@ should be complex", value);
		XCTAssertNil(complex.simpleRef);
	}

	PBGitRevSpecifier *pathLimited = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"HEAD", @"--", @"Sources" ]];
	XCTAssertTrue(pathLimited.hasPathLimiter);
	XCTAssertEqualObjects(pathLimited.title, @"“Sources”");
}

- (void)testRevisionSpecifierCopyAndWellKnownFilters
{
	PBGitRevSpecifier *source = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"main", @"--", @"file.txt" ] description:@"selection"];
	source.workingDirectory = [NSURL fileURLWithPath:@"/tmp"];
	PBGitRevSpecifier *copy = [source copy];
	XCTAssertNotEqual(source, copy);
	XCTAssertEqualObjects(source.parameters, copy.parameters);
	XCTAssertEqualObjects(source.description, copy.description);
	XCTAssertEqualObjects(source.workingDirectory, copy.workingDirectory);
	XCTAssertTrue(PBGitRevSpecifier.allBranchesRevSpec.isAllBranchesRev);
	XCTAssertTrue(PBGitRevSpecifier.localBranchesRevSpec.isLocalBranchesRev);
}

- (void)testSourceViewHierarchySortsFindsAndPrunesChildren
{
	PBSourceViewItem *root = [PBSourceViewItem groupItemWithTitle:@"Root"];
	PBSourceViewItem *folder = [PBSourceViewItem itemWithTitle:@"Folder"];
	PBSourceViewItem *bravo = [PBSourceViewItem itemWithTitle:@"Bravo"];
	PBSourceViewItem *alpha = [PBSourceViewItem itemWithTitle:@"Alpha"];
	PBGitRevSpecifier *revision = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"refs/heads/topic" ]];
	PBSourceViewItem *revisionItem = [PBSourceViewItem itemWithRevSpec:revision];
	PBGitRevSpecifier *otherRevision = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"HEAD~1" ]];
	PBSourceViewItem *otherRevisionItem = [PBSourceViewItem itemWithRevSpec:otherRevision];
	XCTAssertEqualObjects(otherRevisionItem.revSpecifier, otherRevision);

	[root addChild:folder];
	[folder addChild:bravo];
	[folder addChild:alpha];
	[folder addChild:revisionItem];

	XCTAssertEqualObjects([folder.sortedChildren valueForKey:@"title"], (@[ @"Alpha", @"Bravo", @"topic" ]));
	XCTAssertTrue([[folder description] containsString:@"Folder"]);
	XCTAssertEqualObjects([alpha valueForKey:@"stringValue"], @"Alpha");
	XCTAssertEqual([root findRev:revision], revisionItem);

	NSUInteger childCount = folder.sortedChildren.count;
	[folder removeChild:nil];
	XCTAssertEqual(folder.sortedChildren.count, childCount, @"Removing a nil child should be a no-op");

	[folder removeChild:alpha];
	[folder removeChild:bravo];
	[folder removeChild:revisionItem];
	XCTAssertEqual(root.sortedChildren.count, (NSUInteger)0, @"An empty non-group folder should prune itself");
}

- (void)testErrorAndLoggingCompatibilityHelpers
{
	NSError *underlying = [NSError errorWithDomain:@"GitXTests" code:7 userInfo:nil];
	NSDictionary *customInfo = @{@"custom" : @"value"};
	XCTAssertNotNil([NSError pb_errorWithDescription:@"description" failureReason:@"reason"]);
	XCTAssertEqualObjects([NSError pb_errorWithDescription:@"description" failureReason:@"reason" userInfo:customInfo].userInfo[@"custom"], @"value");
	XCTAssertEqualObjects([NSError pb_errorWithDescription:@"description" failureReason:@"reason" underlyingError:underlying].userInfo[NSUnderlyingErrorKey], underlying);
	XCTAssertEqualObjects([NSError pb_errorWithDescription:@"description" failureReason:@"reason" underlyingError:underlying userInfo:customInfo].domain, PBGitXErrorDomain);

	NSError *error = nil;
	XCTAssertFalse(PBReturnError(&error, @"description", @"reason", underlying));
	XCTAssertNotNil(error);
	XCTAssertFalse(PBReturnError(NULL, @"description", @"reason", underlying));
	error = nil;
	XCTAssertFalse(PBReturnErrorWithUserInfo(&error, @"description", @"reason", customInfo));
	XCTAssertNotNil(error);
	XCTAssertFalse(PBReturnErrorWithUserInfo(NULL, @"description", @"reason", customInfo));
	error = nil;
	XCTAssertFalse(PBReturnErrorWithBuilder(&error, ^{
		return underlying;
	}));
	XCTAssertEqualObjects(error, underlying);
	XCTAssertFalse(PBReturnErrorWithBuilder(NULL, ^{
		return underlying;
	}));

	PBLogFunctionImpl(__FUNCTION__, nil);
	PBLogFunctionImpl(__FUNCTION__, @"formatted %@", @"message");
	PBLogErrorImpl(__FUNCTION__, nil);
	PBLogErrorImpl(__FUNCTION__, underlying);
}

@end


@interface GitXRepositoryIntegrationTests : GitXRepositoryTestCase
@end


@implementation GitXRepositoryIntegrationTests

- (void)testRepositoryDiscoversHeadAndReferences
{
	XCTAssertFalse(self.repository.isBareRepository);
	XCTAssertFalse(self.repository.isShallowRepository);
	XCTAssertEqualObjects(self.repository.workingDirectory.stringByResolvingSymlinksInPath,
						  self.fixture.path.stringByResolvingSymlinksInPath);
	XCTAssertEqualObjects(self.repository.projectName, self.fixture.path.lastPathComponent);
	XCTAssertEqualObjects(self.repository.getIndexURL.path.stringByResolvingSymlinksInPath,
						  [[self.fixture.path stringByAppendingPathComponent:@".git/index"] stringByResolvingSymlinksInPath]);
	XCTAssertEqualObjects(self.repository.gitIgnoreFilename.lastPathComponent, @".gitignore");
	XCTAssertEqualObjects(self.repository.gitIgnoreFilename.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath,
						  self.fixture.path.stringByResolvingSymlinksInPath);
	XCTAssertFalse(self.repository.hasSVNRemote);
	XCTAssertFalse(self.repository.hasSVNRemote, @"The cached SVN result should remain stable");
	XCTAssertNotNil(self.repository.headOID);
	XCTAssertEqualObjects(self.repository.headRef.ref.ref, @"refs/heads/main");
	XCTAssertTrue([self.repository revisionExists:@"HEAD"]);
	XCTAssertFalse([self.repository revisionExists:@"refs/heads/missing"]);

	PBGitRef *main = [self.repository refForName:@"main"];
	XCTAssertEqualObjects(main.ref, @"refs/heads/main");
	XCTAssertTrue([self.repository refExists:main]);
	XCTAssertTrue([self.repository checkRefFormat:@"refs/heads/valid-name"]);
	XCTAssertFalse([self.repository checkRefFormat:@"invalid ref"]);
}

- (void)testCreateReloadAndDeleteBranchAndTag
{
	NSError *error = nil;
	XCTAssertTrue([self.repository createBranch:@"feature/integration" atRefish:self.repository.headRef.ref error:&error], @"%@", error);
	XCTAssertTrue([self.repository createTag:@"v-test" message:@"integration tag" atRefish:self.repository.headRef.ref error:&error], @"%@", error);
	[self.repository reloadRefs];

	PBGitRef *branch = [self.repository refForName:@"feature/integration"];
	PBGitRef *tag = [self.repository refForName:@"v-test"];
	XCTAssertNotNil(branch);
	XCTAssertNotNil(tag);
	XCTAssertTrue([self.repository refExists:branch]);
	XCTAssertTrue([self.repository refExists:tag]);
	XCTAssertTrue([self.repository deleteRef:branch error:&error], @"%@", error);
	XCTAssertTrue([self.repository deleteRef:tag error:&error], @"%@", error);
	XCTAssertFalse([self.repository refExists:branch]);
	XCTAssertFalse([self.repository refExists:tag]);
}

- (void)testManualRevisionRefreshReloadsExternallyChangedHeadAndBranches
{
	NSError *error = nil;
	[self.repository readCurrentBranch];
	XCTAssertEqualObjects(self.repository.currentBranch.simpleRef, @"refs/heads/main");
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"-b", @"feature/manual-refresh" ] error:&error]), @"%@", error);

	[self.repository forceUpdateRevisions];

	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"refs/heads/feature/manual-refresh");
	XCTAssertNotNil([self.repository refForName:@"feature/manual-refresh"]);
	XCTAssertEqualObjects(self.repository.currentBranch.simpleRef, @"refs/heads/main");
}

- (void)testManualRevisionRefreshReloadsRefsWhileViewingComplexRevision
{
	NSError *error = nil;
	self.repository.currentBranch = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"HEAD~0" ]];
	XCTAssertFalse(self.repository.currentBranch.isSimpleRef);
	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"refs/heads/main");
	XCTAssertNil([self.repository refForName:@"feature/complex-refresh"]);
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"-b", @"feature/complex-refresh" ] error:&error]), @"%@", error);

	[self.repository forceUpdateRevisions];

	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"refs/heads/feature/complex-refresh");
	XCTAssertNotNil([self.repository refForName:@"feature/complex-refresh"]);
	XCTAssertFalse(self.repository.currentBranch.isSimpleRef);
}

- (void)testRemoteDiscoveryUsesLocalFixture
{
	NSError *error = nil;
	XCTAssertTrue([self.repository addRemote:@"origin" withURL:self.fixture.path error:&error], @"%@", error);
	XCTAssertEqualObjects(self.repository.remotes, (@[ @"origin" ]));
	XCTAssertTrue(self.repository.hasRemotes);
	NSString *fetchOutput = [self.fixture git:@[ @"fetch", @"--quiet", @"origin" ] error:&error];
	XCTAssertNotNil(fetchOutput, @"%@", error);
	[self.repository reloadRefs];
	XCTAssertNotNil([self.repository refForName:@"origin/main"]);
}

- (void)testRepositoryDiscoversExternallyConfiguredRemoteBeforeFetch
{
	NSError *error = nil;
	NSString *remotePath = [self.fixture.path stringByAppendingString:@"-configured-remote.git"];
	@try {
		XCTAssertNotNil(([self.fixture git:@[ @"init", @"--bare", @"--quiet", remotePath ] error:&error]), @"%@", error);
		XCTAssertNotNil(([self.fixture git:@[ @"remote", @"add", @"cli-added", remotePath ] error:&error]), @"%@", error);

		XCTAssertEqualObjects(self.repository.remotes, (@[ @"cli-added" ]));
		XCTAssertNil([self.repository refForName:@"cli-added/main"], @"An unfetched remote should not need tracking refs to be discoverable");
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:remotePath error:nil];
	}
}

- (void)testSidebarIncludesExternallyConfiguredRemoteBeforeFetch
{
	NSError *error = nil;
	NSString *remotePath = [self.fixture.path stringByAppendingString:@"-sidebar-remote.git"];
	@try {
		XCTAssertNotNil(([self.fixture git:@[ @"init", @"--bare", @"--quiet", remotePath ] error:&error]), @"%@", error);
		PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository superController:nil];
		(void)sidebar.view;
		PBGitRevSpecifier *otherRevision = [[PBGitRevSpecifier alloc] initWithParameters:@[ @"HEAD~1" ]];
		PBSourceViewItem *otherRevisionItem = [sidebar addRevSpec:otherRevision];
		XCTAssertEqualObjects(otherRevisionItem.revSpecifier, otherRevision);
		[sidebar selectCurrentBranch];
		XCTAssertGreaterThanOrEqual(sidebar.sourceView.selectedRow, (NSInteger)0);
		XCTAssertFalse([sidebar outlineView:sidebar.sourceView shouldSelectItem:sidebar.remotes]);
		XCTAssertFalse([sidebar outlineView:sidebar.sourceView shouldEditTableColumn:nil item:sidebar.remotes]);
		XCTAssertFalse([[[sidebar.remotes.sortedChildren valueForKey:@"title"] copy] containsObject:@"cli-added"]);

		XCTAssertNotNil(([self.fixture git:@[ @"remote", @"add", @"cli-added", remotePath ] error:&error]), @"%@", error);
		XCTAssertNil([self.repository refForName:@"cli-added/main"]);
		[self.repository reloadRefs];
		NSArray<NSString *> *remoteNames = [sidebar.remotes.sortedChildren valueForKey:@"title"];
		XCTAssertTrue([remoteNames containsObject:@"cli-added"], @"The sidebar should not require fetched tracking refs to show a configured remote");
		[sidebar closeView];
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:remotePath error:nil];
	}
}

- (void)testDeletingRemoteBranchRemovesOnlyLocalTrackingReference
{
	NSError *error = nil;
	NSString *remotePath = [self.fixture.path stringByAppendingString:@"-tracking-remote.git"];
	@try {
		XCTAssertNotNil(([self.fixture git:@[ @"init", @"--bare", @"--quiet", remotePath ] error:&error]), @"%@", error);
		XCTAssertTrue([self.repository addRemote:@"origin" withURL:remotePath error:&error], @"%@", error);
		XCTAssertNotNil(([self.fixture git:@[ @"push", @"--quiet", @"--set-upstream", @"origin", @"main" ] error:&error]), @"%@", error);
		[self.repository reloadRefs];

		PBGitRef *trackingBranch = [self.repository refForName:@"origin/main"];
		XCTAssertNotNil(trackingBranch);
		XCTAssertEqualObjects(trackingBranch.refishType, kGitXRemoteBranchType);
		NSString *remoteHeadBefore = [self.fixture git:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/heads/main" ] error:&error];
		XCTAssertNotNil(remoteHeadBefore, @"%@", error);

		XCTAssertTrue([self.repository deleteRef:trackingBranch error:&error], @"%@", error);
		XCTAssertNil([self.repository refForName:@"origin/main"]);
		NSString *remoteHeadAfter = [self.fixture git:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/heads/main" ] error:&error];
		XCTAssertEqualObjects(remoteHeadAfter, remoteHeadBefore, @"Removing a tracking ref must not delete the server branch");
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:remotePath error:nil];
	}
}

- (void)testPushToSelectedRemoteAndFailurePreservesLocalHead
{
	NSError *error = nil;
	NSString *remotePath = [self.fixture.path stringByAppendingString:@"-push-remote.git"];
	@try {
		XCTAssertNotNil(([self.fixture git:@[ @"init", @"--bare", @"--quiet", remotePath ] error:&error]), @"%@", error);
		XCTAssertTrue([self.repository addRemote:@"origin" withURL:remotePath error:&error], @"%@", error);
		PBGitRef *branchRef = self.repository.headRef.ref;
		PBGitRef *remoteRef = [PBGitRef refFromString:@"refs/remotes/origin"];
		XCTAssertTrue([self.repository pushBranch:branchRef toRemote:remoteRef error:&error], @"%@", error);

		NSString *localHead = [self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error];
		NSString *remoteHead = [self.fixture git:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/heads/main" ] error:&error];
		XCTAssertEqualObjects(localHead, remoteHead);

		XCTAssertTrue([self.fixture writeText:@"local commit retained after push failure\n" toPath:@"failure.txt" error:&error], @"%@", error);
		XCTAssertTrue([self.fixture commitAllWithMessage:@"local commit before failed push" error:&error], @"%@", error);
		NSString *headBeforeFailure = [self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error];
		NSString *missingRemotePath = [remotePath stringByAppendingString:@"-missing"];
		XCTAssertNotNil(([self.fixture git:@[ @"remote", @"set-url", @"origin", missingRemotePath ] error:&error]), @"%@", error);

		error = nil;
		XCTAssertFalse([self.repository pushBranch:branchRef toRemote:remoteRef error:&error]);
		XCTAssertNotNil(error);
		XCTAssertEqualObjects(([self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]), headBeforeFailure);
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:remotePath error:nil];
	}
}

- (void)testPushTagToSelectedRemote
{
	NSError *error = nil;
	NSString *remotePath = [self.fixture.path stringByAppendingString:@"-tag-remote.git"];
	@try {
		XCTAssertNotNil(([self.fixture git:@[ @"init", @"--bare", @"--quiet", remotePath ] error:&error]), @"%@", error);
		XCTAssertTrue([self.repository addRemote:@"origin" withURL:remotePath error:&error], @"%@", error);
		XCTAssertTrue([self.repository createTag:@"v-selected" message:@"" atRefish:self.repository.headRef.ref error:&error], @"%@", error);
		PBGitRef *tag = [self.repository refForName:@"v-selected"];
		PBGitRef *remote = [PBGitRef refFromString:@"refs/remotes/origin"];
		XCTAssertNotNil(tag);
		XCTAssertEqualObjects(tag.refishType, kGitXTagType);

		XCTAssertTrue([self.repository pushBranch:tag toRemote:remote error:&error], @"%@", error);
		NSString *localTag = [self.fixture git:@[ @"rev-parse", @"refs/tags/v-selected" ] error:&error];
		NSString *remoteTag = [self.fixture git:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/tags/v-selected" ] error:&error];
		XCTAssertEqualObjects(remoteTag, localTag);
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:remotePath error:nil];
	}
}

- (void)testDetachedHeadIsRepresentedByHeadSpecifier
{
	NSError *error = nil;
	NSString *checkoutOutput = [self.fixture git:@[ @"checkout", @"--quiet", @"--detach", @"HEAD" ] error:&error];
	XCTAssertNotNil(checkoutOutput, @"%@", error);
	self.repository = nil;
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);
	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"HEAD");
	XCTAssertEqualObjects(self.repository.headRef.title, @"“detached HEAD”");
	XCTAssertNotNil(self.repository.headOID);
}

- (void)testBareAndShallowRepositoryDiscovery
{
	NSError *error = nil;
	NSString *barePath = [self.fixture.path stringByAppendingString:@"-bare.git"];
	NSString *shallowPath = [self.fixture.path stringByAppendingString:@"-shallow"];
	@try {
		NSString *bareOutput = [self.fixture git:@[ @"clone", @"--bare", @"--quiet", self.fixture.path, barePath ] error:&error];
		XCTAssertNotNil(bareOutput, @"%@", error);
		PBGitRepository *bare = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:barePath] error:&error];
		XCTAssertNotNil(bare, @"%@", error);
		XCTAssertTrue(bare.isBareRepository);
		XCTAssertFalse(bare.isShallowRepository);
		XCTAssertNotNil(bare.headOID);

		XCTAssertTrue([self.fixture writeText:@"second commit\n" toPath:@"second.txt" error:&error], @"%@", error);
		XCTAssertTrue([self.fixture commitAllWithMessage:@"second commit" error:&error], @"%@", error);
		NSString *sourceURL = [NSURL fileURLWithPath:self.fixture.path].absoluteString;
		NSString *shallowOutput = [self.fixture git:@[ @"clone", @"--quiet", @"--depth", @"1", sourceURL, shallowPath ] error:&error];
		XCTAssertNotNil(shallowOutput, @"%@", error);
		PBGitRepository *shallow = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:shallowPath] error:&error];
		XCTAssertNotNil(shallow, @"%@", error);
		XCTAssertTrue(shallow.isShallowRepository);
		NSString *commitCount = [PBTask outputForCommand:PBGitBinary.path arguments:@[ @"rev-list", @"--count", @"HEAD" ] inDirectory:shallowPath error:&error];
		XCTAssertEqualObjects([commitCount stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], @"1");
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:barePath error:nil];
		[[NSFileManager defaultManager] removeItemAtPath:shallowPath error:nil];
	}
}

- (void)testLinkedWorktreeDiscovery
{
	NSError *error = nil;
	NSString *worktreePath = [self.fixture.path stringByAppendingString:@"-worktree"];
	PBGitRepository *worktree = nil;
	@try {
		NSString *output = [self.fixture git:@[ @"worktree", @"add", @"--quiet", @"-b", @"linked", worktreePath ] error:&error];
		XCTAssertNotNil(output, @"%@", error);
		worktree = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:worktreePath] error:&error];
		XCTAssertNotNil(worktree, @"%@", error);
		XCTAssertEqualObjects(worktree.workingDirectory.stringByResolvingSymlinksInPath,
							  worktreePath.stringByResolvingSymlinksInPath);
		XCTAssertEqualObjects(worktree.headRef.ref.branchName, @"linked");
	} @finally {
		worktree = nil;
		[self.fixture git:@[ @"worktree", @"remove", @"--force", worktreePath ] error:nil];
		[[NSFileManager defaultManager] removeItemAtPath:worktreePath error:nil];
	}
}

- (void)testSubmoduleDiscovery
{
	NSError *error = nil;
	GitXTestRepository *submoduleSource = [[GitXTestRepository alloc] initWithError:&error];
	XCTAssertNotNil(submoduleSource, @"%@", error);
	XCTAssertTrue([submoduleSource writeText:@"child\n" toPath:@"child.txt" error:&error], @"%@", error);
	XCTAssertTrue([submoduleSource commitAllWithMessage:@"child commit" error:&error], @"%@", error);
	NSString *output = [self.fixture git:@[ @"-c", @"protocol.file.allow=always", @"submodule", @"add", @"--quiet", submoduleSource.path, @"Modules/Child" ] error:&error];
	XCTAssertNotNil(output, @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"add submodule" error:&error], @"%@", error);
	[self.repository reloadRefs];
	XCTAssertEqual(self.repository.submodules.count, 1);
	XCTAssertNotNil([self.repository submoduleAtPath:@"Modules/Child" error:&error], @"%@", error);
}

- (void)testCommitGraphDecoratesMergeHistory
{
	NSError *error = nil;
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"-b", @"topic" ] error:&error]));
	XCTAssertTrue([self.fixture writeText:@"topic\n" toPath:@"topic.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"topic commit" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"main" ] error:&error]));
	XCTAssertTrue([self.fixture writeText:@"main\n" toPath:@"main.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"main commit" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"merge", @"--quiet", @"--no-ff", @"topic", @"-m", @"merge topic" ] error:&error]));

	NSString *revisionOutput = [self.fixture git:@[ @"rev-list", @"--topo-order", @"--all" ] error:&error];
	NSArray<NSString *> *revisions = [revisionOutput componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
	PBGitGrapher *grapher = [[PBGitGrapher alloc] init];
	__block long maximumColumns = 0;
	for (NSString *SHA in revisions) {
		if (!SHA.length) continue;
		GTCommit *gtCommit = [self.repository.gtRepo lookUpObjectBySHA:SHA objectType:GTObjectTypeCommit error:&error];
		XCTAssertNotNil(gtCommit, @"%@", error);
		PBGitCommit *commit = [[PBGitCommit alloc] initWithRepository:self.repository andCommit:gtCommit];
		[grapher decorateCommit:commit];
		XCTAssertNotNil(commit.lineInfo);
		maximumColumns = MAX(maximumColumns, commit.lineInfo.numColumns);
	}
	XCTAssertGreaterThanOrEqual(maximumColumns, 2, @"A merge should use at least two graph lanes");
}

- (void)testNormalHistoryLoadPublishesEveryCommitOnce
{
	NSError *error = nil;
	for (NSUInteger index = 0; index < 4; index++) {
		NSString *path = [NSString stringWithFormat:@"history-%lu.txt", (unsigned long)index];
		XCTAssertTrue([self.fixture writeText:path toPath:path error:&error], @"%@", error);
		XCTAssertTrue([self.fixture commitAllWithMessage:path error:&error], @"%@", error);
	}
	NSString *expectedText = [self.fixture git:@[ @"rev-list", @"--count", @"HEAD" ] error:&error];
	NSUInteger expectedCount = expectedText.integerValue;

	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	[self waitForHistoryUpdate];

	NSArray<PBGitCommit *> *commits = self.repository.revisionList.commits;
	NSSet<NSString *> *uniqueSHAs = [NSSet setWithArray:[commits valueForKey:@"SHA"]];
	XCTAssertEqual(commits.count, expectedCount);
	XCTAssertEqual(uniqueSHAs.count, expectedCount);
}

- (void)testRapidHistoryRefreshKeepsAUniqueNonemptySnapshot
{
	NSError *error = nil;
	for (NSUInteger index = 0; index < 12; index++) {
		NSString *path = [NSString stringWithFormat:@"rapid-history-%lu.txt", (unsigned long)index];
		XCTAssertTrue([self.fixture writeText:path toPath:path error:&error], @"%@", error);
		XCTAssertTrue([self.fixture commitAllWithMessage:path error:&error], @"%@", error);
	}
	NSUInteger expectedCount = [[self.fixture git:@[ @"rev-list", @"--count", @"HEAD" ] error:&error] integerValue];
	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	[self waitForHistoryUpdate];

	PBGitHistoryList *history = self.repository.revisionList;
	XCTAssertEqual(history.commits.count, expectedCount);
	NSMutableArray<NSNumber *> *publishedCounts = [NSMutableArray array];
	__weak PBGitHistoryList *weakHistory = history;
	id<MAKVOObservation> observation = [history addObserver:self
													keyPath:@"commits"
													options:0
													  block:^(__unused MAKVONotification *notification) {
														  [publishedCounts addObject:@(weakHistory.commits.count)];
													  }];

	[self.repository forceUpdateRevisions];
	XCTAssertEqual(history.commits.count, expectedCount, @"Refresh should retain the previous snapshot until replacement data is ready");
	[self.repository forceUpdateRevisions];
	[self waitForHistoryUpdate];
	[observation remove];

	NSArray<PBGitCommit *> *commits = history.commits;
	NSSet<NSString *> *uniqueSHAs = [NSSet setWithArray:[commits valueForKey:@"SHA"]];
	XCTAssertFalse([publishedCounts containsObject:@0], @"A nonempty refresh should not flash an empty commit list");
	XCTAssertEqual(commits.count, expectedCount);
	XCTAssertEqual(uniqueSHAs.count, expectedCount);
}

- (void)testUnchangedSymlinkRenameUsesRenameMetadata
{
	NSError *error = nil;
	NSString *oldPath = [self.fixture.path stringByAppendingPathComponent:@"linked.json"];
	NSString *newPath = [self.fixture.path stringByAppendingPathComponent:@"moved-link.json"];
	XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:oldPath withDestinationPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"add symlink" error:&error], @"%@", error);
	XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"rename symlink" error:&error], @"%@", error);

	NSString *diff = [self.fixture git:@[ @"diff", @"--find-renames", @"--no-ext-diff", @"HEAD^", @"HEAD" ] error:&error];
	XCTAssertNotNil(diff, @"%@", error);
	XCTAssertTrue([diff containsString:@"similarity index 100%"]);
	XCTAssertTrue([diff containsString:@"rename from linked.json"]);
	XCTAssertTrue([diff containsString:@"rename to moved-link.json"]);
	XCTAssertFalse([diff containsString:@"deleted file mode"]);
	XCTAssertFalse([diff containsString:@"new file mode"]);

	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSArray<NSString *> *lines = [diff componentsSeparatedByString:@"\n"];
	XCTAssertEqualObjects([view pathForDiffHeaderAtIndex:0 lines:lines], @"moved-link.json");
}

- (void)testConfiguredRelativeHooksPathRunsExecutablePreCommitHook
{
	NSError *error = nil;
	NSString *marker = @"configured pre-commit hook ran";
	NSString *hook = [NSString stringWithFormat:@"#!/bin/sh\nprintf '%@\\n'\nexit 23\n", marker];
	XCTAssertTrue([self.fixture writeText:hook toPath:@".githooks/pre-commit" error:&error], @"%@", error);
	NSString *hookPath = [self.fixture.path stringByAppendingPathComponent:@".githooks/pre-commit"];
	NSDictionary *attributes = @{NSFilePosixPermissions : @0755};
	XCTAssertTrue([[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:hookPath error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"core.hooksPath", @".githooks" ] error:&error]), @"%@", error);
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);
	XCTAssertTrue([self.repository hookExists:@"pre-commit"]);

	NSError *hookError = nil;
	XCTAssertFalse([self.repository executeHook:@"pre-commit" error:&hookError]);
	XCTAssertEqualObjects(hookError.userInfo[PBHookNameErrorKey], @"pre-commit");
	NSError *taskError = hookError.userInfo[NSUnderlyingErrorKey];
	XCTAssertEqualObjects(taskError.userInfo[PBTaskTerminationStatusKey], @23);
	XCTAssertTrue([taskError.userInfo[PBTaskTerminationOutputKey] containsString:marker]);
	XCTAssertTrue([hookError.localizedFailureReason containsString:marker]);

	XCTAssertNotNil(([self.fixture git:@[ @"config", @"core.hooksPath", @"/dev/null" ] error:&error]), @"%@", error);
	XCTAssertFalse([self.repository hookExists:@"pre-commit"]);
	NSError *disabledHookError = nil;
	XCTAssertTrue([self.repository executeHook:@"pre-commit" error:&disabledHookError]);
	XCTAssertNil(disabledHookError);
}

- (void)testHeadCommitAncestryAndBranchFilterBoundaries
{
	NSError *error = nil;
	NSString *initialSHA = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertNotNil(initialSHA, @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"second\n" toPath:@"second.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"second commit" error:&error], @"%@", error);

	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	[self waitForHistoryUpdate];

	PBGitCommit *head = self.repository.headCommit;
	PBGitCommit *initialCommit = nil;
	for (PBGitCommit *commit in self.repository.revisionList.projectCommits) {
		if ([commit.SHA isEqualToString:initialSHA]) {
			initialCommit = commit;
			break;
		}
	}
	GTOID *initialOID = initialCommit.OID;
	XCTAssertNotNil(head);
	XCTAssertNotNil(initialOID);
	XCTAssertTrue([self.repository isOIDOnSameBranch:head.OID asOID:initialOID]);
	XCTAssertTrue([self.repository isOIDOnSameBranch:head.OID asOID:head.OID]);
	XCTAssertFalse([self.repository isOIDOnSameBranch:nil asOID:head.OID]);
	XCTAssertTrue([self.repository isOIDOnHeadBranch:initialOID]);
	XCTAssertFalse([self.repository isOIDOnHeadBranch:nil]);
	XCTAssertTrue([self.repository isRefOnHeadBranch:self.repository.headRef.ref]);
	XCTAssertFalse([self.repository isRefOnHeadBranch:nil]);
	XCTAssertNil([self.repository OIDForRef:nil]);
	XCTAssertNil([self.repository commitForRef:nil]);
	XCTAssertNil([self.repository commitForOID:nil]);

	self.repository.currentBranchFilter = kGitXAllBranchesFilter;
	self.repository.currentBranchFilter = kGitXSelectedBranchFilter;
	self.repository.hasChanged = NO;
	[self.repository lazyReload];
	self.repository.hasChanged = YES;
	[self.repository lazyReload];
}

- (void)testSelectedBranchBaseCommitsUseTheCurrentBranchTip
{
	[self.repository readCurrentBranch];
	self.repository.currentBranchFilter = kGitXSelectedBranchFilter;
	GTOID *expectedOID = [self.repository OIDForRef:self.repository.currentBranch.ref];
	XCTAssertNotNil(expectedOID);

	PBGitHistoryList *history = [[PBGitHistoryList alloc] initWithRepository:self.repository];
	XCTAssertEqualObjects([history baseCommits], [NSSet setWithObject:expectedOID]);
	[history cleanup];
}

- (void)testStashLifecycleAndNewIgnoreFile
{
	NSError *error = nil;
	XCTAssertEqual(self.repository.stashes.count, (NSUInteger)0);
	XCTAssertNil([self.repository stashForRef:[PBGitRef refFromString:@"refs/stash@{0}"]]);

	XCTAssertTrue([self.fixture writeText:@"working change\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.repository stashSave:&error], @"%@", error);
	PBGitStash *stash = self.repository.stashes.firstObject;
	XCTAssertNotNil(stash);
	XCTAssertTrue([[self.repository stashForRef:stash.ref].ref isEqualToRef:stash.ref]);
	XCTAssertTrue([self.repository stashApply:stash error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] error:&error]), @"%@", error);
	XCTAssertTrue([self.repository stashPop:stash error:&error], @"%@", error);
	XCTAssertEqual(self.repository.stashes.count, (NSUInteger)0);

	XCTAssertNotNil(([self.fixture git:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"staged change\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"add", @"tracked.txt" ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"unstaged\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.repository stashSaveWithKeepIndex:YES error:&error], @"%@", error);
	stash = self.repository.stashes.firstObject;
	XCTAssertNotNil(stash);
	XCTAssertTrue([self.repository stashDrop:stash error:&error], @"%@", error);
	XCTAssertEqual(self.repository.stashes.count, (NSUInteger)0);

	NSArray<NSString *> *ignoredPaths = @[ @"build/", @"*.temporary" ];
	XCTAssertTrue([self.repository ignoreFilePaths:ignoredPaths error:&error], @"%@", error);
	NSString *ignoreContents = [NSString stringWithContentsOfFile:self.repository.gitIgnoreFilename
														 encoding:NSUTF8StringEncoding
															error:&error];
	XCTAssertEqualObjects(ignoreContents, [ignoredPaths componentsJoinedByString:@"\n"]);
}

- (void)testRemoteTrackingFetchPullAndDeletionWorkflows
{
	NSError *error = nil;
	NSString *remotePath = [self.fixture.path stringByAppendingString:@"-workflow-remote.git"];
	@try {
		PBGitRef *main = self.repository.headRef.ref;
		NSError *missingTrackingError = nil;
		XCTAssertNil([self.repository remoteRefForBranch:main error:&missingTrackingError]);
		XCTAssertNotNil(missingTrackingError);

		XCTAssertNotNil(([self.fixture git:@[ @"init", @"--bare", @"--quiet", remotePath ] error:&error]), @"%@", error);
		XCTAssertTrue([self.repository addRemote:@"origin" withURL:remotePath error:&error], @"%@", error);
		XCTAssertNotNil(([self.fixture git:@[ @"push", @"--quiet", @"--set-upstream", @"origin", @"main" ] error:&error]), @"%@", error);
		[self.repository reloadRefs];

		PBGitRef *tracking = [self.repository remoteRefForBranch:main error:&error];
		XCTAssertEqualObjects(tracking.ref, @"refs/remotes/origin/main");
		XCTAssertEqualObjects([self.repository remoteRefForBranch:tracking error:&error].ref, @"refs/remotes/origin");
		XCTAssertTrue([self.repository fetchRemoteForRef:nil error:&error], @"%@", error);
		XCTAssertTrue([self.repository fetchRemoteForRef:main error:&error], @"%@", error);
		XCTAssertTrue([self.repository pullBranch:main fromRemote:nil rebase:NO error:&error], @"%@", error);
		XCTAssertTrue([self.repository pullBranch:main fromRemote:tracking.remoteRef rebase:YES error:&error], @"%@", error);

		PBGitRef *remote = [PBGitRef refFromString:@"refs/remotes/origin"];
		XCTAssertTrue([self.repository deleteRemote:remote error:&error], @"%@", error);
		XCTAssertFalse(self.repository.hasRemotes);
		XCTAssertFalse([self.repository deleteRemote:main error:&error]);
		XCTAssertFalse([self.repository deleteRemote:nil error:&error]);
	} @finally {
		[[NSFileManager defaultManager] removeItemAtPath:remotePath error:nil];
	}
}

- (void)testCheckoutFilesMergeAndExpectedMutationFailures
{
	NSError *error = nil;
	XCTAssertTrue([self.repository createBranch:@"topic" atRefish:self.repository.headRef.ref error:&error], @"%@", error);
	PBGitRef *topic = [self.repository refForName:@"topic"];
	XCTAssertTrue([self.repository checkoutRefish:topic error:&error], @"%@", error);
	XCTAssertEqualObjects(self.repository.headRef.ref.branchName, @"topic");

	XCTAssertTrue([self.fixture writeText:@"topic work\n" toPath:@"topic.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"topic work" error:&error], @"%@", error);
	PBGitRef *main = [self.repository refForName:@"main"];
	XCTAssertTrue([self.repository checkoutRefish:main error:&error], @"%@", error);
	XCTAssertTrue([self.repository mergeWithRefish:topic error:&error], @"%@", error);
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.fixture.path stringByAppendingPathComponent:@"topic.txt"]]);

	XCTAssertTrue([self.fixture writeText:@"local edit\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.repository checkoutFiles:@[ @"tracked.txt" ] fromRefish:self.repository.headRef.ref error:&error], @"%@", error);
	XCTAssertFalse([self.repository checkoutFiles:@[] fromRefish:self.repository.headRef.ref error:&error]);
	XCTAssertFalse([self.repository checkoutFiles:nil fromRefish:self.repository.headRef.ref error:&error]);
	XCTAssertFalse([self.repository cherryPickRefish:nil error:&error]);
	XCTAssertFalse([self.repository resetRefish:GTRepositoryResetTypeHard to:nil error:&error]);
	XCTAssertFalse([self.repository createBranch:nil atRefish:self.repository.headRef.ref error:&error]);
	XCTAssertFalse([self.repository createBranch:@"missing-target" atRefish:nil error:&error]);
	XCTAssertFalse([self.repository createTag:nil message:@"" atRefish:self.repository.headRef.ref error:&error]);
	XCTAssertFalse([self.repository deleteRef:nil error:&error]);

	NSError *checkoutError = nil;
	PBGitRef *missing = [PBGitRef refFromString:@"refs/heads/does-not-exist"];
	XCTAssertFalse([self.repository checkoutRefish:missing error:&checkoutError]);
	XCTAssertNotNil(checkoutError);

	error = nil;
	XCTAssertTrue([self.repository createTag:@"checkout-point" message:@"" atRefish:self.repository.headRef.ref error:&error], @"%@", error);
	PBGitRef *tag = [self.repository refForName:@"checkout-point"];
	XCTAssertTrue([self.repository checkoutRefish:tag error:&error], @"%@", error);
	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"HEAD");
}

- (void)testCherryPickResetAndRebaseWorkflows
{
	NSError *error = nil;
	NSString *initialSHA = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"-b", @"cherry-source" ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"cherry\n" toPath:@"cherry.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"cherry source" error:&error], @"%@", error);
	NSString *cherrySHA = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"main" ] error:&error]), @"%@", error);
	[self.repository reloadRefs];

	PBGitRef *cherry = [PBGitRef refFromString:@"refs/heads/cherry-source"];
	XCTAssertTrue([self.repository cherryPickRefish:cherry error:&error], @"%@", error);
	PBGitRef *initial = [PBGitRef refFromString:initialSHA];
	XCTAssertTrue([self.repository resetRefish:GTRepositoryResetTypeSoft to:initial error:&error], @"%@", error);
	PBGitRef *cherryCommit = [PBGitRef refFromString:cherrySHA];
	XCTAssertTrue([self.repository resetRefish:GTRepositoryResetTypeMixed to:cherryCommit error:&error], @"%@", error);
	XCTAssertTrue([self.repository resetRefish:GTRepositoryResetTypeHard to:initial error:&error], @"%@", error);

	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"-B", @"main", initialSHA ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"upstream\n" toPath:@"upstream.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"upstream" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"checkout", @"--quiet", @"-B", @"rebasing", initialSHA ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"topic\n" toPath:@"rebasing.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"rebasing" error:&error], @"%@", error);
	[self.repository reloadRefs];
	PBGitRef *main = [self.repository refForName:@"main"];
	XCTAssertTrue([self.repository rebaseBranch:nil onRefish:main error:&error], @"%@", error);
}

- (void)testDiffReferenceUpdateMissingSubmoduleAndSuccessfulHookOutput
{
	NSError *error = nil;
	NSString *initialSHA = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertTrue([self.fixture writeText:@"second line\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"second" error:&error], @"%@", error);
	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	[self waitForHistoryUpdate];

	PBGitCommit *head = self.repository.headCommit;
	PBGitCommit *initial = nil;
	for (PBGitCommit *commit in self.repository.revisionList.projectCommits) {
		if ([commit.SHA isEqualToString:initialSHA]) {
			initial = commit;
			break;
		}
	}
	XCTAssertNotNil(head);
	XCTAssertNotNil(initial);
	if (head == nil || initial == nil) {
		XCTFail(@"Expected both initial and HEAD commits before testing the diff");
		return;
	}
	NSString *diff = [self.repository performDiff:initial against:head forFiles:@[ @"tracked.txt" ]];
	XCTAssertTrue([diff containsString:@"tracked.txt"]);
	XCTAssertEqualObjects([self.repository performDiff:head against:nil forFiles:nil], @"");

	XCTAssertTrue([self.repository createBranch:@"movable" atRefish:initial error:&error], @"%@", error);
	PBGitRef *movable = [self.repository refForName:@"movable"];
	XCTAssertTrue([self.repository updateReference:movable toPointAtCommit:head error:&error], @"%@", error);
	NSString *movedSHA = [[self.fixture git:@[ @"rev-parse", @"refs/heads/movable" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertEqualObjects(movedSHA, head.SHA);

	NSError *submoduleError = nil;
	XCTAssertNil([self.repository submoduleAtPath:@"Missing/Child" error:&submoduleError]);
	XCTAssertNotNil(submoduleError);

	NSString *hook = @"#!/bin/sh\nprintf 'hook:%s' \"$1\"\n";
	XCTAssertTrue([self.fixture writeText:hook toPath:@".git/hooks/gitx-success" error:&error], @"%@", error);
	NSString *hookPath = [self.fixture.path stringByAppendingPathComponent:@".git/hooks/gitx-success"];
	XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755}
												   ofItemAtPath:hookPath
														  error:&error],
				  @"%@", error);
	NSString *output = nil;
	XCTAssertTrue([self.repository executeHook:@"gitx-success" arguments:@[ @"argument" ] output:&output error:&error], @"%@", error);
	XCTAssertEqualObjects(output, @"hook:argument");
}

- (void)testRepositoryInitializationAndRemoteFailureErrors
{
	NSError *error = nil;
	NSString *notARepository = [NSTemporaryDirectory() stringByAppendingPathComponent:
														   [NSString stringWithFormat:@"GitXNotARepository-%@", NSUUID.UUID.UUIDString]];
	XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:notARepository
											withIntermediateDirectories:YES
															 attributes:nil
																  error:&error]);
	PBGitRepository *invalid = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:notARepository] error:&error];
	XCTAssertNil(invalid);
	XCTAssertNotNil(error);
	[[NSFileManager defaultManager] removeItemAtPath:notARepository error:nil];

	error = nil;
	PBGitRef *missingRemote = [PBGitRef refFromString:@"refs/remotes/missing"];
	XCTAssertFalse([self.repository fetchRemoteForRef:missingRemote error:&error]);
	XCTAssertNotNil(error);
	XCTAssertFalse([self.repository addRemote:@"origin" withURL:@"/path/that/does/not/exist" error:&error]);
}

- (void)testMutationFailuresReturnStructuredErrors
{
	NSError *error = nil;
	[self.repository readCurrentBranch];
	[self waitForHistoryUpdate];
	PBGitCommit *head = self.repository.headCommit;
	PBGitRef *missing = [PBGitRef refFromString:@"refs/heads/does-not-exist"];
	XCTAssertNotNil(head);

	XCTAssertFalse([self.repository checkoutFiles:@[ @"tracked.txt" ] fromRefish:missing error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([self.repository mergeWithRefish:missing error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([self.repository cherryPickRefish:missing error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([self.repository resetRefish:GTRepositoryResetTypeHard to:missing error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([self.repository rebaseBranch:nil onRefish:missing error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([self.repository rebaseBranch:self.repository.headRef.ref onRefish:missing error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([self.repository createBranch:@"invalid branch name" atRefish:self.repository.headRef.ref error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	PBGitRef *invalid = [PBGitRef refFromString:@"refs/heads/invalid branch name"];
	XCTAssertFalse([self.repository updateReference:invalid toPointAtCommit:head error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	PBGitRef *empty = [PBGitRef refFromString:@""];
	XCTAssertFalse([self.repository deleteRef:empty error:&error]);
	XCTAssertNotNil(error);

	error = nil;
	XCTAssertTrue([self.fixture writeText:@"stashed once\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.repository stashSave:&error], @"%@", error);
	PBGitStash *stash = self.repository.stashes.firstObject;
	XCTAssertTrue([self.repository stashDrop:stash error:&error], @"%@", error);
	error = nil;
	XCTAssertFalse([self.repository stashDrop:stash error:&error]);
	XCTAssertNotNil(error);

	error = nil;
	XCTAssertNil([self.repository remoteRefForBranch:missing error:&error]);
	XCTAssertNotNil(error);
}

@end


@interface GitXIndexIntegrationTests : GitXRepositoryTestCase

- (NSString *)installHookNamed:(NSString *)name contents:(NSString *)contents error:(NSError **)error;
- (PBChangedFile *)stageTrackedText:(NSString *)text error:(NSError **)error;

@end


@implementation GitXIndexIntegrationTests

- (NSString *)installHookNamed:(NSString *)name contents:(NSString *)contents error:(NSError **)error
{
	NSString *relativePath = [@".git/hooks" stringByAppendingPathComponent:name];
	XCTAssertTrue([self.fixture writeText:contents toPath:relativePath error:error], @"%@", *error);
	NSString *path = [self.fixture.path stringByAppendingPathComponent:relativePath];
	XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755}
												   ofItemAtPath:path
														  error:error],
				  @"%@", *error);
	return path;
}

- (PBChangedFile *)stageTrackedText:(NSString *)text error:(NSError **)error
{
	XCTAssertTrue([self.fixture writeText:text toPath:@"tracked.txt" error:error], @"%@", *error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertNotNil(tracked);
	XCTAssertTrue([self.repository.index stageFiles:@[ tracked ]]);
	return tracked;
}

- (void)testPrepareCommitMessageRunsHookAndTrimsOneTrailingNewline
{
	NSError *error = nil;
	[self installHookNamed:@"prepare-commit-msg"
				  contents:@"#!/bin/sh\nprintf 'prepared message\\n' > \"$1\"\n"
					 error:&error];

	NSString *message = [self.repository.index createPrepareCommitMessage];

	XCTAssertEqualObjects(message, @"prepared message");
}

- (void)testPrepareCommitMessageFailurePublishesHookOutput
{
	NSError *error = nil;
	[self installHookNamed:@"prepare-commit-msg"
				  contents:@"#!/bin/sh\nprintf 'prepare was blocked\\n' >&2\nexit 17\n"
					 error:&error];
	__block NSNotification *failure = nil;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexCommitHookFailed
					object:self.repository.index
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					failure = notification;
				}];

	NSString *message = [self.repository.index createPrepareCommitMessage];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	XCTAssertNil(message);
	XCTAssertTrue([failure.userInfo[@"description"] containsString:@"prepare was blocked"]);
}

- (void)testPrepareCommitMessageForAmendPassesCommitAndHeadSHA
{
	NSError *error = nil;
	NSString *argumentsPath = [self.fixture.path stringByAppendingPathComponent:@"prepare-arguments.txt"];
	NSString *hook = [NSString stringWithFormat:@"#!/bin/sh\nprintf '%%s|%%s' \"$2\" \"$3\" > '%@'\nprintf 'amended message\\n' > \"$1\"\n", argumentsPath];
	[self installHookNamed:@"prepare-commit-msg" contents:hook error:&error];
	NSString *headSHA = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	self.repository.index.amend = YES;

	NSString *message = [self.repository.index createPrepareCommitMessage];
	NSString *arguments = [NSString stringWithContentsOfFile:argumentsPath encoding:NSUTF8StringEncoding error:&error];
	NSString *expectedArguments = [NSString stringWithFormat:@"commit|%@", headSHA];

	XCTAssertEqualObjects(message, @"amended message");
	XCTAssertEqualObjects(arguments, expectedArguments);
}

- (void)testVerifiedCommitRunsHooksAndPublishesSuccess
{
	NSError *error = nil;
	[self stageTrackedText:@"verified contents\n" error:&error];
	NSString *markerPath = [self.fixture.path stringByAppendingPathComponent:@"hook-order.txt"];
	[self installHookNamed:@"pre-commit"
				  contents:[NSString stringWithFormat:@"#!/bin/sh\nprintf 'pre\\n' >> '%@'\n", markerPath]
					 error:&error];
	[self installHookNamed:@"commit-msg"
				  contents:[NSString stringWithFormat:@"#!/bin/sh\nprintf 'message:%%s\\n' \"$(head -n 1 \"$1\")\" >> '%@'\n", markerPath]
					 error:&error];
	[self installHookNamed:@"post-commit"
				  contents:[NSString stringWithFormat:@"#!/bin/sh\nprintf 'post\\n' >> '%@'\n", markerPath]
					 error:&error];
	__block NSNotification *finished = nil;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexFinishedCommit
					object:self.repository.index
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					finished = notification;
				}];

	[self.repository.index commitWithMessage:@"verified subject\nbody" andVerify:YES];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	NSString *message = [self.fixture git:@[ @"show", @"-s", @"--format=%B", @"HEAD" ] error:&error];
	NSString *hookOrder = [NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:&error];
	XCTAssertEqualObjects(message, @"verified subject\nbody\n");
	XCTAssertEqualObjects(hookOrder, @"pre\nmessage:verified subject\npost\n");
	XCTAssertEqualObjects(finished.userInfo[@"success"], @YES);
	XCTAssertEqual([finished.userInfo[@"sha"] length], 40);
}

- (void)testPreCommitFailurePublishesOutputAndDoesNotMoveHead
{
	NSError *error = nil;
	[self stageTrackedText:@"blocked contents\n" error:&error];
	[self installHookNamed:@"pre-commit"
				  contents:@"#!/bin/sh\nprintf 'pre-commit denied\\n' >&2\nexit 19\n"
					 error:&error];
	NSString *originalHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	__block NSNotification *failure = nil;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexCommitHookFailed
					object:self.repository.index
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					failure = notification;
				}];

	[self.repository.index commitWithMessage:@"blocked commit" andVerify:YES];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	NSString *currentHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertEqualObjects(currentHead, originalHead);
	XCTAssertTrue([failure.userInfo[@"description"] containsString:@"pre-commit denied"]);
}

- (void)testCommitMessageFailurePublishesOutputAndDoesNotMoveHead
{
	NSError *error = nil;
	[self stageTrackedText:@"message blocked contents\n" error:&error];
	[self installHookNamed:@"commit-msg"
				  contents:@"#!/bin/sh\nprintf 'message denied\\n' >&2\nexit 21\n"
					 error:&error];
	NSString *originalHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	__block NSNotification *failure = nil;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexCommitHookFailed
					object:self.repository.index
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					failure = notification;
				}];

	[self.repository.index commitWithMessage:@"blocked message" andVerify:YES];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	NSString *currentHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertEqualObjects(currentHead, originalHead);
	XCTAssertTrue([failure.userInfo[@"description"] containsString:@"message denied"]);
}

- (void)testSigningFailurePublishesCommitObjectFailure
{
	NSError *error = nil;
	[self stageTrackedText:@"signed contents\n" error:&error];
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"commit.gpgSign", @"true" ] error:&error]), @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"gpg.program", @"gitx-missing-gpg" ] error:&error]), @"%@", error);
	__block NSNotification *failure = nil;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexCommitFailed
					object:self.repository.index
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					failure = notification;
				}];

	[self.repository.index commitWithMessage:@"signed commit" andVerify:NO];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	XCTAssertEqualObjects(failure.userInfo[@"description"], @"Could not create a commit object");
}

- (void)testRefUpdateFailurePublishesFailureAndLeavesHeadUnchanged
{
	NSError *error = nil;
	[self stageTrackedText:@"locked ref contents\n" error:&error];
	NSString *originalHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *lockPath = [self.fixture.path stringByAppendingPathComponent:@".git/refs/heads/main.lock"];
	XCTAssertTrue([NSData.data writeToFile:lockPath options:NSDataWritingAtomic error:&error], @"%@", error);
	__block NSNotification *failure = nil;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexCommitFailed
					object:self.repository.index
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					failure = notification;
				}];

	[self.repository.index commitWithMessage:@"locked ref commit" andVerify:NO];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	[[NSFileManager defaultManager] removeItemAtPath:lockPath error:nil];
	NSString *currentHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertEqualObjects(currentHead, originalHead);
	XCTAssertEqualObjects(failure.userInfo[@"description"], @"Could not update HEAD");
}

- (void)testRefreshStageAndUnstageTrackedAndUnicodePaths
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"first line\nsecond line\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"new contents\n" toPath:@"folder/spaced ünicode.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	PBChangedFile *untracked = [self changedFileAtPath:@"folder/spaced ünicode.txt"];
	XCTAssertNotNil(tracked);
	XCTAssertNotNil(untracked);
	XCTAssertEqual(tracked.status, MODIFIED);
	XCTAssertEqual(untracked.status, NEW);
	XCTAssertTrue(tracked.hasUnstagedChanges);
	XCTAssertTrue(untracked.hasUnstagedChanges);

	XCTAssertTrue(([self.repository.index stageFiles:@[ tracked, untracked ]]));
	NSString *cached = [self.fixture git:@[ @"diff", @"--cached", @"--name-only" ] error:&error];
	XCTAssertTrue([cached containsString:@"tracked.txt"]);
	XCTAssertTrue([cached containsString:@"folder/spaced"]);
	XCTAssertTrue(([self.repository.index unstageFiles:@[ tracked, untracked ]]));
	NSString *cachedAfterUnstage = [self.fixture git:@[ @"diff", @"--cached", @"--name-only" ] error:&error];
	XCTAssertEqualObjects(cachedAfterUnstage, @"");
}

- (void)testRepositoryCommandInputWrappersForwardStandardInput
{
	NSError *error = nil;
	NSString *expected = @"e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
	NSString *output = [self.repository outputOfTaskWithArguments:@[ @"hash-object", @"--stdin" ]
															input:@""
															error:&error];
	XCTAssertEqualObjects(output, expected);
	BOOL launched = [self.repository launchTaskWithArguments:@[ @"hash-object", @"-w", @"--stdin" ]
													   input:@"stored through stdin"
													   error:&error];
	XCTAssertTrue(launched, @"%@", error);
	BOOL wrapperLaunched = [self.repository launchTaskWithArguments:@[ @"status", @"--porcelain" ] error:&error];
	XCTAssertTrue(wrapperLaunched, @"%@", error);
}

- (void)testRefreshStatCacheCompletesWithARefreshedSnapshot
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"stat cache refresh\n" toPath:@"tracked.txt" error:&error], @"%@", error);

	[self refreshIndexAfterPerforming:^{
		[self.repository.index refreshStatCache];
	}];

	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertNotNil(tracked);
	XCTAssertTrue(tracked.hasUnstagedChanges);
}

- (void)testDiffAndPatchRoundTrip
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"first line\nchanged line\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertNotNil(tracked);
	NSString *diff = [self.repository.index diffForFile:tracked staged:NO contextLines:3];
	XCTAssertTrue([diff containsString:@"+changed line"]);

	[self refreshIndexAfterPerforming:^{
		XCTAssertTrue([self.repository.index applyPatch:diff stage:YES reverse:NO]);
	}];
	NSString *stagedDiff = [self.fixture git:@[ @"diff", @"--cached" ] error:&error];
	XCTAssertTrue([stagedDiff containsString:@"+changed line"]);

	[self refreshIndexAfterPerforming:^{
		XCTAssertTrue([self.repository.index applyPatch:diff stage:YES reverse:YES]);
	}];
	NSString *unstagedDiff = [self.fixture git:@[ @"diff", @"--cached" ] error:&error];
	XCTAssertEqualObjects(unstagedDiff, @"");
	XCTAssertFalse([self.repository.index applyPatch:@"not a patch\n" stage:YES reverse:NO]);
}

- (void)testRefreshRepresentsPartiallyStagedFileInBothSections
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"first line\nstaged line\nunstaged line\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	NSString *patch = @"diff --git a/tracked.txt b/tracked.txt\n"
					  @"--- a/tracked.txt\n"
					  @"+++ b/tracked.txt\n"
					  @"@@ -1 +1,2 @@\n"
					  @" first line\n"
					  @"+staged line\n";
	[self refreshIndexAfterPerforming:^{
		XCTAssertTrue([self.repository.index applyPatch:patch stage:YES reverse:NO]);
	}];

	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertNotNil(tracked);
	XCTAssertEqual(tracked.status, MODIFIED);
	XCTAssertTrue(tracked.hasStagedChanges);
	XCTAssertTrue(tracked.hasUnstagedChanges);
	NSString *stagedDiff = [self.repository.index diffForFile:tracked staged:YES contextLines:3];
	NSString *unstagedDiff = [self.repository.index diffForFile:tracked staged:NO contextLines:3];
	XCTAssertTrue([stagedDiff containsString:@"+staged line"]);
	XCTAssertFalse([stagedDiff containsString:@"unstaged line"]);
	XCTAssertTrue([unstagedDiff containsString:@"+unstaged line"]);
}

- (void)testRefreshDistinguishesPartiallyStagedAdditionFromUntrackedFile
{
	NSError *error = nil;
	NSString *partiallyStagedPath = @"folder/spaced ünicode.txt";
	XCTAssertTrue([self.fixture writeText:@"first staged line\n" toPath:partiallyStagedPath error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"add", @"--", partiallyStagedPath ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"first staged line\nsecond unstaged line\n" toPath:partiallyStagedPath error:&error], @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"never staged\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	PBChangedFile *partiallyStaged = [self changedFileAtPath:partiallyStagedPath];
	XCTAssertNotNil(partiallyStaged);
	XCTAssertEqual(partiallyStaged.status, NEW);
	XCTAssertTrue(partiallyStaged.hasStagedChanges);
	XCTAssertTrue(partiallyStaged.hasUnstagedChanges);

	PBChangedFile *untracked = [self changedFileAtPath:@"untracked.txt"];
	XCTAssertNotNil(untracked);
	XCTAssertEqual(untracked.status, NEW);
	XCTAssertFalse(untracked.hasStagedChanges);
	XCTAssertTrue(untracked.hasUnstagedChanges);
	XCTAssertEqualObjects([self.repository.index diffForFile:untracked staged:NO contextLines:3], @"never staged\n");

	NSString *cached = [self.fixture git:@[ @"diff", @"--cached", @"--", partiallyStagedPath ] error:&error];
	NSString *working = [self.fixture git:@[ @"diff", @"--", partiallyStagedPath ] error:&error];
	XCTAssertTrue([cached containsString:@"+first staged line"]);
	XCTAssertFalse([cached containsString:@"second unstaged line"]);
	XCTAssertTrue([working containsString:@" first staged line"]);
	XCTAssertTrue([working containsString:@"+second unstaged line"]);

	NSString *stagedDiff = [self.repository.index diffForFile:partiallyStaged staged:YES contextLines:3];
	NSString *unstagedDiff = [self.repository.index diffForFile:partiallyStaged staged:NO contextLines:3];
	XCTAssertTrue([stagedDiff containsString:@"+first staged line"]);
	XCTAssertFalse([stagedDiff containsString:@"second unstaged line"]);
	XCTAssertTrue([unstagedDiff containsString:@" first staged line"]);
	XCTAssertTrue([unstagedDiff containsString:@"+second unstaged line"]);
	XCTAssertFalse([unstagedDiff containsString:@"+first staged line"]);
}

- (void)testWholeFileUnstageAfterPartialStageIgnoresStaleIndexMetadata
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"first line\nstaged line\nunstaged line\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	NSString *patch = @"diff --git a/tracked.txt b/tracked.txt\n"
					  @"--- a/tracked.txt\n"
					  @"+++ b/tracked.txt\n"
					  @"@@ -1 +1,2 @@\n"
					  @" first line\n"
					  @"+staged line\n";
	[self refreshIndexAfterPerforming:^{
		XCTAssertTrue([self.repository.index applyPatch:patch stage:YES reverse:NO]);
	}];

	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertNotNil(tracked);
	tracked.commitBlobMode = @"100644";
	tracked.commitBlobSHA = [[self.fixture git:@[ @"rev-parse", @":tracked.txt" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertTrue([self.repository.index unstageFiles:@[ tracked ]]);

	NSString *stagedNames = [self.fixture git:@[ @"diff", @"--cached", @"--name-only" ] error:&error];
	NSString *workingText = [NSString stringWithContentsOfFile:[self.fixture.path stringByAppendingPathComponent:@"tracked.txt"] encoding:NSUTF8StringEncoding error:&error];
	XCTAssertEqualObjects(stagedNames, @"");
	XCTAssertEqualObjects(workingText, @"first line\nstaged line\nunstaged line\n");
}

- (void)testAmendRefreshTreatsFileAddedByLastCommitAsNew
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"new file\n" toPath:@"amended.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"add file" error:&error], @"%@", error);
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);

	[self refreshIndexAfterPerforming:^{
		self.repository.index.amend = YES;
	}];

	PBChangedFile *added = [self changedFileAtPath:@"amended.txt"];
	XCTAssertNotNil(added);
	XCTAssertEqual(added.status, NEW);
	XCTAssertTrue(added.hasStagedChanges);
	XCTAssertFalse(added.hasUnstagedChanges);
}

- (void)testAmendingOrdinaryCommitPreservesItsParent
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"second commit\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"ordinary commit" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"commit.gpgSign", @"false" ] error:&error]), @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"core.hooksPath", @"/dev/null" ] error:&error]), @"%@", error);

	NSString *originalHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *originalParent = [[self.fixture git:@[ @"rev-parse", @"HEAD^" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);

	[self refreshIndexAfterPerforming:^{
		self.repository.index.amend = YES;
	}];
	[self.repository.index commitWithMessage:@"amended ordinary commit" andVerify:NO];

	NSString *amendedHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *amendedParents = [[self.fixture git:@[ @"show", @"-s", @"--format=%P", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertNotEqualObjects(amendedHead, originalHead);
	XCTAssertEqualObjects(amendedParents, originalParent);
}

- (void)testAmendingMergeCommitPreservesAllParents
{
	NSError *error = nil;
	XCTAssertNotNil(([self.fixture git:@[ @"switch", @"--quiet", @"-c", @"side" ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"side\n" toPath:@"side.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"side commit" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"switch", @"--quiet", @"main" ] error:&error]), @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"main\n" toPath:@"main.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"main commit" error:&error], @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"merge", @"--quiet", @"--no-ff", @"side", @"-m", @"merge side" ] error:&error]), @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"commit.gpgSign", @"false" ] error:&error]), @"%@", error);
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"core.hooksPath", @"/dev/null" ] error:&error]), @"%@", error);

	NSString *originalHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *originalParents = [[self.fixture git:@[ @"show", @"-s", @"--format=%P", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertNotNil(originalHead, @"%@", error);
	XCTAssertEqual([originalParents componentsSeparatedByString:@" "].count, 2);
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);

	[self refreshIndexAfterPerforming:^{
		self.repository.index.amend = YES;
	}];
	[self.repository.index commitWithMessage:@"amended merge commit" andVerify:NO];

	NSString *amendedHead = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *amendedParents = [[self.fixture git:@[ @"show", @"-s", @"--format=%P", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	XCTAssertNotNil(amendedHead, @"%@", error);
	XCTAssertNotEqualObjects(amendedHead, originalHead);
	XCTAssertEqualObjects(amendedParents, originalParents);
}

- (void)testAmendCanUnstageModifiedFileAddedByLastCommit
{
	NSError *error = nil;
	NSString *path = @"folder/spaced ünicode.txt";
	XCTAssertTrue([self.fixture writeText:@"committed\n" toPath:path error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"add file" error:&error], @"%@", error);
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"committed\nmodified\n" toPath:path error:&error], @"%@", error);

	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	XCTAssertEqual([self changedFileAtPath:path].status, MODIFIED);
	[self refreshIndexAfterPerforming:^{
		self.repository.index.amend = YES;
	}];
	PBChangedFile *added = [self changedFileAtPath:path];
	XCTAssertNotNil(added);
	XCTAssertEqual(added.status, NEW);
	XCTAssertTrue(added.hasStagedChanges);
	XCTAssertTrue(added.hasUnstagedChanges);
	XCTAssertTrue([self.repository.index unstageFiles:@[ added ]]);

	NSString *stagedNames = [self.fixture git:@[ @"diff", @"--cached", @"--name-only", @"HEAD^" ] error:&error];
	NSString *indexEntry = [self.fixture git:@[ @"ls-files", @"--stage", @"--", path ] error:&error];
	NSString *workingText = [NSString stringWithContentsOfFile:[self.fixture.path stringByAppendingPathComponent:path] encoding:NSUTF8StringEncoding error:&error];
	XCTAssertEqualObjects(stagedNames, @"");
	XCTAssertEqualObjects(indexEntry, @"");
	XCTAssertEqualObjects(workingText, @"committed\nmodified\n");
}

- (void)testRefreshPublishesOneCoherentIndexUpdate
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"changed\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"untracked\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	__block NSUInteger updateCount = 0;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexIndexUpdated
					object:self.repository.index
					 queue:NSOperationQueue.mainQueue
				usingBlock:^(__unused NSNotification *notification) {
					updateCount++;
				}];

	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	XCTAssertEqual(updateCount, 1);
	XCTAssertNotNil([self changedFileAtPath:@"tracked.txt"]);
	XCTAssertNotNil([self changedFileAtPath:@"untracked.txt"]);
}

- (void)testReadOnlyRefreshSucceedsWhileIndexLockExists
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"changed\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	NSString *lockPath = [self.fixture.path stringByAppendingPathComponent:@".git/index.lock"];
	XCTAssertTrue([NSData.data writeToFile:lockPath options:NSDataWritingAtomic error:&error], @"%@", error);
	__block NSUInteger failureCount = 0;
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexIndexRefreshFailed
					object:self.repository.index
					 queue:NSOperationQueue.mainQueue
				usingBlock:^(__unused NSNotification *notification) {
					failureCount++;
				}];

	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	[[NSFileManager defaultManager] removeItemAtPath:lockPath error:nil];
	XCTAssertEqual(failureCount, 0);
	XCTAssertNotNil([self changedFileAtPath:@"tracked.txt"]);
}

- (void)testRefreshReportsFailureWhenUntrackedScanCannotReadExcludes
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"untracked\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	PBChangedFile *untracked = [self changedFileAtPath:@"untracked.txt"];
	XCTAssertNotNil(untracked);

	NSString *gitDirectory = [self.fixture.path stringByAppendingPathComponent:@".git"];
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"core.excludesFile", gitDirectory ] error:&error]), @"%@", error);
	NSMutableArray<NSString *> *failureDescriptions = [NSMutableArray array];
	id token = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitIndexIndexRefreshFailed
					object:self.repository.index
					 queue:NSOperationQueue.mainQueue
				usingBlock:^(NSNotification *notification) {
					[failureDescriptions addObject:notification.userInfo[@"description"]];
				}];

	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	[[NSNotificationCenter defaultCenter] removeObserver:token];
	XCTAssertNotNil(([self.fixture git:@[ @"config", @"--unset", @"core.excludesFile" ] error:&error]), @"%@", error);
	XCTAssertTrue([failureDescriptions containsObject:@"ls-files failed"]);
	XCTAssertEqual([self changedFileAtPath:@"untracked.txt"], untracked,
				   @"A failed refresh must preserve the last coherent untracked snapshot");
}

- (void)testWholeFileUnstageFailureLeavesIndexUntouched
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"changed\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertTrue([self.repository.index stageFiles:@[ tracked ]]);
	NSString *lockPath = [self.fixture.path stringByAppendingPathComponent:@".git/index.lock"];
	XCTAssertTrue([NSData.data writeToFile:lockPath options:NSDataWritingAtomic error:&error], @"%@", error);

	XCTAssertFalse([self.repository.index unstageFiles:@[ tracked ]]);

	[[NSFileManager defaultManager] removeItemAtPath:lockPath error:nil];
	NSString *stagedNames = [self.fixture git:@[ @"diff", @"--cached", @"--name-only" ] error:&error];
	XCTAssertEqualObjects(stagedNames, @"tracked.txt\n");
}

- (void)testDiscardRestoresTrackedFilesButLeavesUntrackedFiles
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"modified\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"untracked\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	PBChangedFile *untracked = [self changedFileAtPath:@"untracked.txt"];
	[self.repository.index discardChangesForFiles:@[ tracked, untracked ]];
	NSString *trackedText = [NSString stringWithContentsOfFile:[self.fixture.path stringByAppendingPathComponent:@"tracked.txt"] encoding:NSUTF8StringEncoding error:&error];
	XCTAssertEqualObjects(trackedText, @"first line\n");
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.fixture.path stringByAppendingPathComponent:@"untracked.txt"]]);
}

- (void)testDiscardTrackedFileClearsUnstagedStateAndPublishesUpdate
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"modified\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTestExpectation *updated = [self expectationForNotification:PBGitIndexIndexUpdated
														   object:self.repository.index
														  handler:nil];

	[self.repository.index discardChangesForFiles:@[ tracked ]];

	[self waitForExpectations:@[ updated ] timeout:2.0];
	NSString *trackedText = [NSString stringWithContentsOfFile:[self.fixture.path stringByAppendingPathComponent:@"tracked.txt"]
													  encoding:NSUTF8StringEncoding
														 error:&error];
	XCTAssertEqualObjects(trackedText, @"first line\n");
	XCTAssertFalse(tracked.hasUnstagedChanges);
}

- (void)testDiffForMissingUntrackedFileReturnsNil
{
	PBChangedFile *missing = [[PBChangedFile alloc] initWithPath:@"missing-untracked.txt"];
	missing.status = NEW;
	missing.hasUnstagedChanges = YES;

	XCTAssertNil([self.repository.index diffForFile:missing staged:NO contextLines:3]);
}

- (void)testPartialPatchDoesNotCarryNoNewlineMarkerFromOmittedLine
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"a\nold\ntail\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture commitAllWithMessage:@"patch base" error:&error], @"%@", error);
	self.repository = [[PBGitRepository alloc] initWithURL:[NSURL fileURLWithPath:self.fixture.path] error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);

	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSArray *header = @[ @"diff --git a/tracked.txt b/tracked.txt", @"--- a/tracked.txt", @"+++ b/tracked.txt" ];
	NSArray *hunk = @[ @"@@ -1,3 +1,5 @@", @" a", @" old", @"+new", @" tail", @"+extra", @"\\ No newline at end of file" ];
	NSString *patch = [view patchWithFileHeader:header hunkLines:hunk selectedIndexes:[NSIndexSet indexSetWithIndex:3] reverse:NO];
	XCTAssertNotNil(patch);
	XCTAssertFalse([patch containsString:@"No newline at end of file"]);
	XCTAssertTrue([self.repository.index applyPatch:patch stage:YES reverse:NO]);
	NSString *stagedContents = [self.fixture git:@[ @"show", @":tracked.txt" ] error:&error];
	XCTAssertEqualObjects(stagedContents, @"a\nold\nnew\ntail\n");
}

- (void)testWorkingTreeTreatsNulBytesAsBinaryAndUncommittedTreeIsCached
{
	unsigned char bytes[] = {0x89, 0x00, 0x50, 0x4e, 0x47};
	NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
	NSString *path = [self.fixture.path stringByAppendingPathComponent:@"binary.dat"];
	XCTAssertTrue([data writeToFile:path options:NSDataWritingAtomic error:nil]);

	PBWorkingTree *root = [PBWorkingTree rootForRepository:self.repository];
	PBGitTree *binary = [self treeAtPath:@"binary.dat" inRoot:root];
	XCTAssertNotNil(binary);
	XCTAssertEqualObjects(binary.textContents, @"This file cannot be displayed as text.");

	PBUncommittedChanges *changes = [[PBUncommittedChanges alloc] initWithRepository:self.repository];
	PBGitTree *firstTree = changes.tree;
	XCTAssertNotNil(firstTree);
	XCTAssertEqual(firstTree, changes.tree);
}

- (void)testGitTreeBinaryHeuristicsAndLocalCacheDecodingAreDeterministic
{
	unichar binaryCharacters[] = {'a', 0, 'b'};
	NSString *binaryHeader = [NSString stringWithCharacters:binaryCharacters length:3];
	PBGitTree *tree = [[PBGitTree alloc] init];
	tree.repository = self.repository;
	tree.path = @"image.png";
	tree.leaf = YES;
	PBGitTree *root = [[PBGitTree alloc] init];
	root.leaf = NO;
	tree.parent = root;
	XCTAssertTrue([tree hasBinaryHeader:binaryHeader]);
	XCTAssertTrue([tree hasBinaryAttributes]);

	NSString *cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"GitXTreeCache-%@", NSUUID.UUID.UUIDString]];
	unsigned char latin1Byte = 0xE9;
	XCTAssertTrue([[NSData dataWithBytes:&latin1Byte length:1] writeToFile:cachePath atomically:YES]);
	NSDate *modificationDate = [[NSFileManager defaultManager] attributesOfItemAtPath:cachePath error:nil][NSFileModificationDate];
	[tree setValue:cachePath forKey:@"localFileName"];
	[tree setValue:modificationDate forKey:@"localMtime"];
	XCTAssertEqualObjects(tree.contents, @"é");
	[tree setValue:nil forKey:@"localFileName"];
	[[NSFileManager defaultManager] removeItemAtPath:cachePath error:nil];
}

- (void)testWorkingStateCompatibilitySurfaceAndCommittedTreeExport
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"changed working contents\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"new working contents\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	PBUncommittedChanges *changes = [[PBUncommittedChanges alloc] initWithRepository:self.repository];
	XCTAssertEqual(changes.repository, self.repository);
	XCTAssertEqualObjects(changes.authorEmail, @"");
	XCTAssertEqualObjects(changes.authorDate, @"");
	XCTAssertEqualObjects(changes.committer, @"");
	XCTAssertEqualObjects(changes.committerEmail, @"");
	XCTAssertEqualObjects(changes.committerDate, @"");
	XCTAssertEqualObjects(changes.SHA, @"");
	XCTAssertNil(changes.SVNRevision);
	XCTAssertEqual(changes.parents.count, (NSUInteger)0);
	XCTAssertFalse(changes.isOnHeadBranch);
	XCTAssertEqualObjects(changes.refishName, @"WORKING_STATE");
	XCTAssertEqualObjects(changes.refishType, @"working-state");
	XCTAssertTrue([changes.patch containsString:@"+changed working contents"]);

	PBWorkingTree *workingRoot = (PBWorkingTree *)changes.tree;
	XCTAssertEqualObjects(changes.treeContents, workingRoot.children);
	XCTAssertEqualObjects(workingRoot.contents, @"");
	XCTAssertEqualObjects(workingRoot.blame, @"");
	XCTAssertEqualObjects([workingRoot log:@"%H"], @"");

	PBWorkingTree *tracked = (PBWorkingTree *)[self treeAtPath:@"tracked.txt" inRoot:workingRoot];
	XCTAssertNotNil(tracked);
	XCTAssertTrue([tracked.displayPath containsString:@"[M]"]);
	XCTAssertEqualObjects(tracked.contents, @"changed working contents\n");
	XCTAssertEqualObjects(tracked.textContents, tracked.contents);
	XCTAssertFalse(tracked.blame.length == 0);
	XCTAssertFalse([tracked log:@"%H"].length == 0);
	XCTAssertGreaterThan(tracked.fileSize, (long long)0);
	XCTAssertEqualObjects(tracked.tmpFileNameForContents.stringByResolvingSymlinksInPath,
						  [self.fixture.path stringByAppendingPathComponent:@"tracked.txt"].stringByResolvingSymlinksInPath);

	PBWorkingTree *untracked = (PBWorkingTree *)[self treeAtPath:@"untracked.txt" inRoot:workingRoot];
	XCTAssertNotNil(untracked);
	XCTAssertTrue([untracked.displayPath containsString:@"[?]"]);
	XCTAssertTrue([untracked.blame containsString:@"Not Committed Yet"]);

	NSString *headSHA = [[self.fixture git:@[ @"rev-parse", @"HEAD" ] error:&error]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	GTCommit *gtCommit = [self.repository.gtRepo lookUpObjectBySHA:headSHA objectType:GTObjectTypeCommit error:&error];
	XCTAssertNotNil(gtCommit, @"%@", error);
	PBGitCommit *commit = [[PBGitCommit alloc] initWithRepository:self.repository andCommit:gtCommit];
	PBGitTree *committedRoot = commit.tree;
	XCTAssertTrue([committedRoot.contents hasPrefix:@"This is a tree with path"]);
	PBGitTree *committedTracked = [self treeAtPath:@"tracked.txt" inRoot:committedRoot];
	NSString *cachedFile = committedTracked.tmpFileNameForContents;
	XCTAssertEqualObjects(committedTracked.tmpFileNameForContents, cachedFile);
	NSString *exportedDirectory = committedRoot.tmpFileNameForContents;
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:exportedDirectory]);
	NSString *exportedContents = [NSString stringWithContentsOfFile:[exportedDirectory stringByAppendingPathComponent:@"tracked.txt"]
														   encoding:NSUTF8StringEncoding
															  error:&error];
	XCTAssertEqualObjects(exportedContents, @"first line\n", @"%@", error);
}

- (void)testUncommittedChangesSubjectShowsOnlyStats
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"changed\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	XCTAssertTrue([self.fixture writeText:@"new\n" toPath:@"untracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	PBUncommittedChanges *changes = [[PBUncommittedChanges alloc] initWithRepository:self.repository];
	XCTAssertEqualObjects(changes.subject, @"0 staged, 1 unstaged, 1 untracked");
	XCTAssertEqualObjects(changes.message, changes.subject);
	XCTAssertEqualObjects(changes.details, changes.subject);
}

- (void)testUncommittedChangesRefreshesStatsAndInvalidatesCachedTree
{
	NSError *error = nil;
	XCTAssertTrue([self.fixture writeText:@"changed\n" toPath:@"tracked.txt" error:&error], @"%@", error);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];

	PBUncommittedChanges *changes = [[PBUncommittedChanges alloc] initWithRepository:self.repository];
	PBGitTree *unstagedTree = changes.tree;
	PBChangedFile *tracked = [self changedFileAtPath:@"tracked.txt"];
	XCTAssertNotNil(tracked);
	XCTAssertEqual(changes.stagedCount, 0);
	XCTAssertEqual(changes.unstagedCount, 1);

	XCTAssertTrue([self.repository.index stageFiles:@[ tracked ]]);
	[self refreshIndexAfterPerforming:^{
		[self.repository.index refresh];
	}];
	[changes refreshFromRepository];

	XCTAssertEqual(changes.stagedCount, 1);
	XCTAssertEqual(changes.unstagedCount, 0);
	XCTAssertNotEqual(changes.tree, unstagedTree);
}

@end


@interface PBTaskCoreTests : XCTestCase
@end


@implementation PBTaskCoreTests

- (void)testClassAsyncLaunchReturnsCommandOutput
{
	XCTestExpectation *completion = [self expectationWithDescription:@"async task completed"];
	[PBTask launchTask:@"/bin/echo"
				arguments:@[ @"async output" ]
			  inDirectory:nil
		completionHandler:^(NSData *data, NSError *error) {
			XCTAssertNil(error);
			XCTAssertEqualObjects([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], @"async output\n");
			[completion fulfill];
		}];
	[self waitForExpectations:@[ completion ] timeout:5.0];
}

- (void)testTerminationBeforeLaunchReturnsCancellationError
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/usr/bin/true" arguments:@[] inDirectory:nil];
	[task terminate];
	NSError *error = nil;

	XCTAssertFalse([task launchTask:&error]);
	XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
	XCTAssertEqual(error.code, NSUserCancelledError);
}

- (void)testStandardInputRoundTrip
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/bin/cat" arguments:@[] inDirectory:nil];
	task.standardInputData = [@"héllo from stdin\n" dataUsingEncoding:NSUTF8StringEncoding];
	NSError *error = nil;
	XCTAssertTrue([task launchTask:&error], @"%@", error);
	XCTAssertEqualObjects(task.standardOutputString, @"héllo from stdin\n");
}

- (void)testNonZeroExitIncludesStatusAndCombinedOutput
{
	NSError *error = nil;
	NSString *output = [PBTask outputForCommand:@"/bin/sh"
									  arguments:@[ @"-c", @"printf stdout; printf stderr >&2; exit 7" ]
									inDirectory:nil
										  error:&error];
	XCTAssertNil(output);
	XCTAssertEqualObjects(error.domain, PBTaskErrorDomain);
	XCTAssertEqual(error.code, PBTaskNonZeroExitCodeError);
	XCTAssertEqualObjects(error.userInfo[PBTaskTerminationStatusKey], @7);
	NSString *failureOutput = error.userInfo[PBTaskTerminationOutputKey];
	XCTAssertTrue([failureOutput containsString:@"stdout"]);
	XCTAssertTrue([failureOutput containsString:@"stderr"]);
}

- (void)testSignalTerminationReturnsCaughtSignalError
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/bin/sh"
									arguments:@[ @"-c", @"kill -TERM $$" ]
								  inDirectory:nil];
	NSError *error = nil;

	XCTAssertFalse([task launchTask:&error]);
	XCTAssertEqualObjects(error.domain, PBTaskErrorDomain);
	XCTAssertEqual(error.code, PBTaskCaughtSignalError);
	XCTAssertTrue([error.localizedFailureReason containsString:@"caught a termination signal"]);
}

- (void)testNonZeroExitCapturesCompleteLargeOutput
{
	NSError *error = nil;
	NSString *output = [PBTask outputForCommand:@"/bin/sh"
									  arguments:@[ @"-c", @"/usr/bin/seq 1 200000; printf 'large-output-tail\\n'; exit 7" ]
									inDirectory:nil
										  error:&error];
	XCTAssertNil(output);
	XCTAssertEqualObjects(error.domain, PBTaskErrorDomain);
	XCTAssertEqual(error.code, PBTaskNonZeroExitCodeError);
	NSString *failureOutput = error.userInfo[PBTaskTerminationOutputKey];
	XCTAssertGreaterThan(failureOutput.length, (NSUInteger)1000000);
	XCTAssertTrue([failureOutput hasSuffix:@"200000\nlarge-output-tail\n"]);
}

- (void)testMissingExecutableReturnsLaunchError
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/path/that/does/not/exist" arguments:@[] inDirectory:nil];
	NSError *error = nil;
	XCTAssertFalse([task launchTask:&error]);
	XCTAssertEqualObjects(error.domain, PBTaskErrorDomain);
	XCTAssertEqual(error.code, PBTaskLaunchError);
	XCTAssertNotNil(error.userInfo[PBTaskUnderlyingExceptionKey]);
}

- (void)testAsyncCompletionUsesRequestedQueueAndCapturesLargeOutput
{
	static void *queueKey = &queueKey;
	dispatch_queue_t queue = dispatch_queue_create("org.gitx.tests.task-completion", DISPATCH_QUEUE_SERIAL);
	dispatch_queue_set_specific(queue, queueKey, queueKey, NULL);
	XCTestExpectation *expectation = [self expectationWithDescription:@"task completion"];
	PBTask *task = [PBTask taskWithLaunchPath:@"/usr/bin/seq" arguments:@[ @"1", @"10000" ] inDirectory:nil];
	[task performTaskOnQueue:queue
		   completionHandler:^(NSData *data, NSError *error) {
			   XCTAssertTrue(dispatch_get_specific(queueKey) != NULL);
			   XCTAssertNil(error);
			   NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
			   XCTAssertTrue([output hasPrefix:@"1\n2\n"]);
			   XCTAssertTrue([output hasSuffix:@"10000\n"]);
			   [expectation fulfill];
		   }];
	[self waitForExpectations:@[ expectation ] timeout:10.0];
}

- (void)testMainQueueTerminationConvenienceCompletesOnMainThread
{
	XCTestExpectation *expectation = [self expectationWithDescription:@"main queue termination"];
	PBTask *task = [PBTask taskWithLaunchPath:@"/usr/bin/true" arguments:@[] inDirectory:nil];
	[task performTaskWithTerminationHandler:^(NSError *error) {
		XCTAssertTrue(NSThread.isMainThread);
		XCTAssertNil(error);
		[expectation fulfill];
	}];
	[self waitForExpectations:@[ expectation ] timeout:10.0];
}

- (void)testAsyncTimeoutCompletesExactlyOnce
{
	static void *queueKey = &queueKey;
	dispatch_queue_t queue = dispatch_queue_create("org.gitx.tests.task-timeout", DISPATCH_QUEUE_SERIAL);
	dispatch_queue_set_specific(queue, queueKey, queueKey, NULL);
	XCTestExpectation *completionExpectation = [self expectationWithDescription:@"timeout completion"];
	XCTestExpectation *duplicateExpectation = [self expectationWithDescription:@"duplicate completion"];
	duplicateExpectation.inverted = YES;
	__block NSUInteger completionCount = 0;
	PBTask *task = [PBTask taskWithLaunchPath:@"/bin/sleep" arguments:@[ @"0.5" ] inDirectory:nil];
	task.timeout = 0.02;
	[task performTaskOnQueue:queue
		   completionHandler:^(NSData *data, NSError *error) {
			   completionCount += 1;
			   XCTAssertTrue(dispatch_get_specific(queueKey) != NULL);
			   if (completionCount == 1) {
				   XCTAssertNil(data);
				   XCTAssertEqualObjects(error.domain, PBTaskErrorDomain);
				   XCTAssertEqual(error.code, PBTaskTimeoutError);
				   [completionExpectation fulfill];
			   } else {
				   [duplicateExpectation fulfill];
			   }
		   }];
	[self waitForExpectations:@[ completionExpectation ] timeout:0.3];
	[self waitForExpectations:@[ duplicateExpectation ] timeout:0.8];
	XCTAssertEqual(completionCount, (NSUInteger)1);
}

@end

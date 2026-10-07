//
//  PBGitHistoryList.m
//  GitX
//
//  Created by Nathan Kinsinger on 2/20/10.
//  Copyright 2010 Nathan Kinsinger. All rights reserved.
//

#import "PBGitHistoryList.h"
#import "PBGitRepository.h"
#import "PBGitRevList.h"
#import "PBGitCommit.h"
#import "PBGitGrapher.h"
#import "PBGitHistoryGrapher.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"

@interface PBGitHistoryList () <PBGitHistoryGrapherDelegate>

@property (nonatomic) NSMutableSet<NSString *> *publishedCommitSHAs;

- (void)resetGraphing;

- (PBGitHistoryGrapher *)grapher;
- (NSInvocationOperation *)operationForCommits:(NSArray *)newCommits;
- (void)finishGraphingForQueue:(NSOperationQueue *)queue revisionList:(PBGitRevList *)parser;
- (void)finishParsingRevisionList:(PBGitRevList *)parser;

- (void)updateProjectHistoryForRev:(PBGitRevSpecifier *)rev;
- (void)updateHistoryForRev:(PBGitRevSpecifier *)rev;

@end


@implementation PBGitHistoryList


@synthesize projectRevList;
@synthesize commits;
@synthesize isUpdating;
@dynamic projectCommits;


#pragma mark -
#pragma mark Public

- (id)initWithRepository:(PBGitRepository *)repo
{
	self = [super init];
	if (!self)
		return nil;

	commits = [NSMutableArray array];
	repository = repo;
	lastBranchFilter = -1;

	shouldReloadProjectHistory = YES;
	projectRevList = [[PBGitRevList alloc] initWithRepository:repository rev:[PBGitRevSpecifier allBranchesRevSpec] shouldGraph:NO];

	return self;
}

- (void)dealloc
{
	[self cleanup];
}

- (void)forceUpdate
{
	if ([repository.currentBranch isSimpleRef]) {
		shouldReloadProjectHistory = YES;
	} else {
		NSLog(@"[GitX] Manual history refresh reloading refs for a complex revision");
		[repository reloadRefs];
	}

	[self updateHistory];
}


- (void)updateHistory
{
	PBGitRevSpecifier *rev = repository.currentBranch;
	if (!rev)
		return;

	if ([rev isSimpleRef])
		[self updateProjectHistoryForRev:rev];
	else
		[self updateHistoryForRev:rev];
}


- (void)cleanup
{
	if (currentRevList) {
		[currentRevList removeObserver:self keyPath:@"commits"];
		if (currentRevList != projectRevList)
			[currentRevList cancel];
		currentRevList = nil;
	}
	BOOL projectLoadWasActive = projectRevList.isParsing;
	[projectRevList cancel];
	if (projectLoadWasActive)
		NSLog(@"[GitX] Cancelled an active project history load during cleanup");
	// Invalidate the publication token before cancelled graph work can deliver.
	NSOperationQueue *cancelledQueue = graphQueue;
	graphQueue = nil;
	[cancelledQueue cancelAllOperations];
}


- (NSArray *)projectCommits
{
	return [projectRevList.commits copy];
}


#pragma mark -
#pragma mark History Grapher delegate methods

- (void)addCommitsFromArray:(NSArray *)array
{
	if (!array || [array count] == 0)
		return;
	NSMutableArray<PBGitCommit *> *uniqueCommits = [NSMutableArray arrayWithCapacity:array.count];
	for (PBGitCommit *commit in array) {
		if ([self.publishedCommitSHAs containsObject:commit.SHA]) continue;
		[self.publishedCommitSHAs addObject:commit.SHA];
		[uniqueCommits addObject:commit];
	}
	if (uniqueCommits.count == 0) return;

	if (resetCommits) {
		self.commits = [uniqueCommits mutableCopy];
		resetCommits = NO;
		NSLog(@"[GitX] Atomically replaced history with %lu commits", (unsigned long)uniqueCommits.count);
		return;
	}

	NSRange range = NSMakeRange([commits count], [uniqueCommits count]);
	NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:range];

	[self willChange:NSKeyValueChangeInsertion valuesAtIndexes:indexes forKey:@"commits"];
	[commits addObjectsFromArray:uniqueCommits];
	[self didChange:NSKeyValueChangeInsertion valuesAtIndexes:indexes forKey:@"commits"];
}


- (void)updateCommitsFromGrapher:(NSDictionary *)commitData
{
	if ([commitData objectForKey:kCurrentQueueKey] != graphQueue)
		return;

	[self addCommitsFromArray:[commitData objectForKey:kNewCommitsKey]];
}

- (void)finishedGraphing
{
	// The legacy delegate callback is sent before its invocation finishes and
	// carries no source identity. Actual operation completions settle the load.
}

- (void)finishGraphingForQueue:(NSOperationQueue *)queue revisionList:(PBGitRevList *)parser
{
	if (!queue || !parser || queue != graphQueue || parser != currentRevList) {
		NSLog(@"[GitX] Ignored graph completion for a superseded history load");
		return;
	}
	if (parser.isParsing) return;
	for (NSOperation *operation in queue.operations) {
		if (!operation.finished) return;
	}

	if (resetCommits && parser.commits.count == 0) {
		self.commits = [NSMutableArray array];
		self.publishedCommitSHAs = [NSMutableSet set];
		resetCommits = NO;
		NSLog(@"[GitX] Cleared history after an empty revision load");
	}
	self.isUpdating = NO;
	NSLog(@"[GitX] History load finished with %lu commits", (unsigned long)commits.count);
}

- (void)finishParsingRevisionList:(PBGitRevList *)parser
{
	if (!parser || parser != currentRevList) {
		NSLog(@"[GitX] Ignored parser completion for a superseded history source");
		return;
	}
	// The shared project parser may outlive a temporary revision selection.
	// Its own generation gate has accepted this completion; reevaluate the
	// current graph of that source after its parsing operation really finishes.
	[self finishGraphingForQueue:graphQueue revisionList:parser];
}


#pragma mark -
#pragma mark Private

- (void)resetGraphing
{
	resetCommits = YES;
	self.isUpdating = YES;
	self.publishedCommitSHAs = [NSMutableSet set];

	[graphQueue cancelAllOperations];
	graphQueue = [[NSOperationQueue alloc] init];
	[graphQueue setMaxConcurrentOperationCount:1];

	grapher = [self grapher];
}


- (NSInvocationOperation *)operationForCommits:(NSArray *)newCommits
{
	NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:grapher selector:@selector(graphCommits:) object:newCommits];
	__weak typeof(self) weakSelf = self;
	__weak NSOperationQueue *sourceQueue = graphQueue;
	__weak PBGitRevList *sourceParser = currentRevList;
	operation.completionBlock = ^{
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf finishGraphingForQueue:sourceQueue revisionList:sourceParser];
		});
	};
	return operation;
}


- (NSSet *)baseCommitsForLocalRefs
{
	NSMutableSet *baseCommitOIDs = [NSMutableSet set];
	NSDictionary *refs = repository.refs;

	for (GTOID *OID in refs)
		for (PBGitRef *ref in [refs objectForKey:OID])
			if ([ref isBranch] || [ref isTag])
				[baseCommitOIDs addObject:OID];

	if (![[PBGitRef refFromString:[[repository headRef] simpleRef]] type]) {
		// An unborn branch (fresh `git init`) has HEAD as a symbolic ref with no target, so headOID is nil.
		GTOID *headOID = repository.headOID;
		if (headOID)
			[baseCommitOIDs addObject:headOID];
	}

	return baseCommitOIDs;
}


- (NSSet *)baseCommitsForRemoteRefs
{
	NSMutableSet *baseCommitOIDs = [NSMutableSet set];
	NSDictionary *refs = repository.refs;

	PBGitRef *remoteRef = [[repository.currentBranch ref] remoteRef];

	for (GTOID *OID in refs)
		for (PBGitRef *ref in [refs objectForKey:OID])
			if ([remoteRef isEqualToRef:[ref remoteRef]])
				[baseCommitOIDs addObject:OID];

	return baseCommitOIDs;
}


- (NSSet *)baseCommits
{
	if ((repository.currentBranchFilter == kGitXSelectedBranchFilter) || (repository.currentBranchFilter == kGitXAllBranchesFilter)) {
		if (lastOID)
			return [NSMutableSet setWithObject:lastOID];
		else if ([repository.currentBranch isSimpleRef]) {
			PBGitRef *currentRef = [repository.currentBranch ref];
			GTOID *OID = [repository OIDForRef:currentRef];
			if (OID)
				return [NSMutableSet setWithObject:OID];
		}
	} else if (repository.currentBranchFilter == kGitXLocalRemoteBranchesFilter) {
		if ([[repository.currentBranch ref] isRemote])
			return [self baseCommitsForRemoteRefs];
		else
			return [self baseCommitsForLocalRefs];
	}

	return [NSMutableSet set];
}


- (PBGitHistoryGrapher *)grapher
{
	BOOL viewAllBranches = (repository.currentBranchFilter == kGitXAllBranchesFilter);

	return [[PBGitHistoryGrapher alloc] initWithBaseCommits:[self baseCommits] viewAllBranches:viewAllBranches queue:graphQueue delegate:self];
}


- (void)setCurrentRevList:(PBGitRevList *)parser
{
	if (currentRevList == parser)
		return;

	if (currentRevList) {
		[currentRevList removeObserver:self keyPath:@"commits"];
		// Keep the shared all-branches load alive while a transient revision is
		// selected. Returning to a branch can then graph the complete project
		// snapshot instead of commits published before cancellation.
		if (currentRevList != projectRevList)
			[currentRevList cancel];
	}

	currentRevList = parser;

	[currentRevList addObserver:self
						keyPath:@"commits"
						options:NSKeyValueObservingOptionNew
						  block:^(MAKVONotification *notification) {
							  PBGitHistoryList *observer = notification.observer;
							  if (notification.kind == NSKeyValueChangeInsertion || notification.kind == NSKeyValueChangeSetting) {
								  id payload = notification.newValue;
								  if (![payload isKindOfClass:NSArray.class]) {
									  NSLog(@"[GitX] Ignored invalid history KVO payload of type %@", [payload class]);
									  return;
								  }
								  NSArray *newCommits = payload;
								  if (newCommits.count == 0) return;
								  if ([observer->repository.currentBranch isSimpleRef])
									  [observer->graphQueue addOperation:[observer operationForCommits:newCommits]];
								  else
									  [observer addCommitsFromArray:newCommits];
							  }
						  }];
}


- (BOOL)isAllBranchesOnlyUpdate
{
	return (lastBranchFilter == kGitXAllBranchesFilter) && (repository.currentBranchFilter == kGitXAllBranchesFilter);
}


- (BOOL)isLocalRemoteOnlyUpdate:(PBGitRevSpecifier *)rev
{
	if ((lastBranchFilter == kGitXLocalRemoteBranchesFilter) && (repository.currentBranchFilter == kGitXLocalRemoteBranchesFilter)) {
		if (!lastRemoteRef && ![[rev ref] isRemote])
			return YES;

		if ([lastRemoteRef isEqualToRef:[[rev ref] remoteRef]])
			return YES;
	}

	return NO;
}


- (BOOL)selectedBranchNeedsNewGraph:(PBGitRevSpecifier *)rev
{
	if (![rev isSimpleRef])
		return YES;

	if ([self isAllBranchesOnlyUpdate] || [self isLocalRemoteOnlyUpdate:rev]) {
		lastRemoteRef = [[rev ref] remoteRef];
		lastOID = nil;
		self.isUpdating = NO;
		return NO;
	}

	GTOID *revOID = [repository OIDForRef:[rev ref]];
	if ([revOID isEqual:lastOID] && (lastBranchFilter == repository.currentBranchFilter))
		return NO;

	lastBranchFilter = repository.currentBranchFilter;
	lastRemoteRef = [[rev ref] remoteRef];
	lastOID = revOID;

	return YES;
}


- (BOOL)haveRefsBeenModified
{
	[repository reloadRefs];

	NSMutableSet *currentRefOIDs = [NSMutableSet setWithArray:[repository.refs allKeys]];
	[currentRefOIDs minusSet:lastRefOIDs];
	lastRefOIDs = [NSSet setWithArray:[repository.refs allKeys]];

	return [currentRefOIDs count] != 0;
}


#pragma mark updating history

- (void)updateProjectHistoryForRev:(PBGitRevSpecifier *)rev
{
	[self setCurrentRevList:projectRevList];

	if ([self haveRefsBeenModified])
		shouldReloadProjectHistory = YES;

	if (![self selectedBranchNeedsNewGraph:rev] && !shouldReloadProjectHistory)
		return;

	[self resetGraphing];

	if (shouldReloadProjectHistory) {
		shouldReloadProjectHistory = NO;
		lastBranchFilter = -1;
		lastRemoteRef = nil;
		lastOID = nil;
		__weak typeof(self) weakSelf = self;
		__weak PBGitRevList *sourceParser = projectRevList;
		[projectRevList loadRevisionsWithCompletionBlock:^{
			dispatch_async(dispatch_get_main_queue(), ^{
				[weakSelf finishParsingRevisionList:sourceParser];
			});
		}];
	} else {
		[graphQueue addOperation:[self operationForCommits:projectRevList.commits]];
	}
}


- (void)updateHistoryForRev:(PBGitRevSpecifier *)rev
{
	PBGitRevList *otherRevListParser = [[PBGitRevList alloc] initWithRepository:repository rev:rev shouldGraph:YES];

	[self setCurrentRevList:otherRevListParser];
	[self resetGraphing];
	lastBranchFilter = -1;
	lastRemoteRef = nil;
	lastOID = nil;

	__weak typeof(self) weakSelf = self;
	__weak PBGitRevList *sourceParser = otherRevListParser;
	[otherRevListParser loadRevisionsWithCompletionBlock:^{
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf finishParsingRevisionList:sourceParser];
		});
	}];
}

@end

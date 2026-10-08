//
//  PBGitIndex.m
//  GitX
//
//  Created by Pieter de Bie on 9/12/09.
//  Copyright 2009 Pieter de Bie. All rights reserved.
//

#import "PBGitIndex.h"
#import "PBGitRepository.h"
#import "PBTask.h"
#import "PBChangedFile.h"
#import "GitX-Swift.h"

NSString *PBGitIndexIndexRefreshStatus = @"PBGitIndexIndexRefreshStatus";
NSString *PBGitIndexIndexRefreshFailed = @"PBGitIndexIndexRefreshFailed";
NSString *PBGitIndexFinishedIndexRefresh = @"PBGitIndexFinishedIndexRefresh";

NSString *PBGitIndexIndexUpdated = @"PBGitIndexIndexUpdated";

NSString *PBGitIndexCommitStatus = @"PBGitIndexCommitStatus";
NSString *PBGitIndexCommitOutput = @"PBGitIndexCommitOutput";
NSString *PBGitIndexCommitFailed = @"PBGitIndexCommitFailed";
NSString *PBGitIndexCommitHookFailed = @"PBGitIndexCommitHookFailed";
NSString *PBGitIndexFinishedCommit = @"PBGitIndexFinishedCommit";

NSString *PBGitIndexAmendMessageAvailable = @"PBGitIndexAmendMessageAvailable";
NSString *PBGitIndexOperationFailed = @"PBGitIndexOperationFailed";

NS_ENUM(NSUInteger, PBGitIndexOperation){
	PBGitIndexStageFiles,
	PBGitIndexUnstageFiles,
};

@interface PBGitIndex () {
	BOOL _amend;
}

@property (retain) NSDictionary *amendEnvironment;
@property (retain) NSMutableArray<PBChangedFile *> *files;
@property (retain) PBIndexStatusParser *statusParser;
@property (retain) PBIndexSnapshotReducer *snapshotReducer;
@property (retain) PBIndexMutationService *mutationService;
@property (retain) PBIndexMutationCoordinator *mutationCoordinator;
@property (readwrite) NSUInteger writerPendingCount;
@property (readwrite) NSUInteger writerActiveCount;
@property BOOL closed;
@property (retain) PBIndexCommitService *commitService;
@property (retain) PBIndexCommitCoordinator *commitCoordinator;
@property (retain) PBIndexRefreshCoordinator *refreshCoordinator;
@property (readwrite) BOOL mutationReconciliationPending;
@property (readwrite) NSUInteger snapshotRevision;
@property (readwrite) BOOL publishingSnapshot;
@property (readwrite) BOOL submissionActive;
@property (readwrite) BOOL awaitingHookDecision;
@property (retain, nullable) PBIndexCommitRequest *retainedCommitRequest;
@property NSUInteger mutationGeneration;
@property NSUInteger reconciledMutationGeneration;
@property NSUInteger postMutationStatCacheRefreshesPending;
@end

@implementation PBGitIndex

- (id)initWithRepository:(PBGitRepository *)theRepository
{
	if (!(self = [super init]))
		return nil;

	NSAssert(theRepository, @"PBGitIndex requires a repository");

	_repository = theRepository;

	_files = [NSMutableArray array];
	_statusParser = [[PBIndexStatusParser alloc] init];
	_snapshotReducer = [[PBIndexSnapshotReducer alloc] init];
	_mutationService = [[PBIndexMutationService alloc] initWithRepository:theRepository];
	_commitService = [[PBIndexCommitService alloc] initWithRepository:theRepository];
	_commitCoordinator = [[PBIndexCommitCoordinator alloc] initWithService:_commitService repository:theRepository];
	__weak PBGitIndex *weakSelf = self;
	_mutationCoordinator = [[PBIndexMutationCoordinator alloc] initWithRepository:theRepository
																		  service:_mutationService
																	 stateHandler:^(PBIndexWriterState *state) {
																		 weakSelf.writerPendingCount = state.pendingCount;
																		 weakSelf.writerActiveCount = state.activeCount;
																	 }];
	_refreshCoordinator = [[PBIndexRefreshCoordinator alloc] initWithRepository:theRepository
		parser:_statusParser
		statusHandler:^(BOOL success, NSString *message) {
			[weakSelf postIndexRefreshSuccess:success message:message];
		}
		resultHandler:^(PBIndexRefreshResult *result) {
			[weakSelf applyRefreshResult:result];
		}
		idleHandler:^{
			[weakSelf postIndexRefreshFinished];
		}];

	return self;
}

- (NSArray *)indexChanges
{
	return self.files;
}

- (void)setAmend:(BOOL)newAmend
{
	if (newAmend == _amend)
		return;

	_amend = newAmend;
	self.amendEnvironment = nil;
	// HEAD and HEAD^ describe different index snapshots. Invalidate a queued
	// result for the previous comparison before publishing the new context.
	self.mutationGeneration++;
	self.mutationReconciliationPending = YES;

	[self refresh];

	if (!newAmend)
		return;

	// If we amend, we want to keep the author information for the previous commit
	// We do this by reading in the previous commit, and storing the information
	// in a dictionary. This dictionary will then later be read by [self commit:]
	GTReference *headRef = [self.repository.gtRepo headReferenceWithError:NULL];
	GTCommit *commit = [headRef resolvedTarget];
	if (commit) {
		GTSignature *author = commit.author;
		NSMutableDictionary<NSString *, NSString *> *environment = [NSMutableDictionary dictionary];
		if (author.name)
			environment[@"GIT_AUTHOR_NAME"] = author.name;
		if (author.email)
			environment[@"GIT_AUTHOR_EMAIL"] = author.email;
		// Preserve the original *author* date and its timezone, not the committer date. The value must be a
		// git-parseable string ("@<unixtime> <±HHMM>"); the previous code stored the committer NSDate, which
		// NSTask stringified to UTC and lost the author's timezone.
		if (author.time) {
			NSTimeZone *timeZone = author.timeZone ?: [NSTimeZone timeZoneForSecondsFromGMT:0];
			NSInteger offset = [timeZone secondsFromGMTForDate:author.time];
			NSInteger absOffset = labs(offset);
			environment[@"GIT_AUTHOR_DATE"] = [NSString stringWithFormat:@"@%lld %c%02ld%02ld",
																		 (long long)llround(author.time.timeIntervalSince1970),
																		 offset < 0 ? '-' : '+',
																		 (long)(absOffset / 3600),
																		 (long)((absOffset % 3600) / 60)];
		}
		self.amendEnvironment = environment;
	}

	NSDictionary *notifDict = nil;
	if (commit.message) {
		notifDict = @{@"message" : commit.message};
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexAmendMessageAvailable
														object:self
													  userInfo:notifDict];
}

- (BOOL)isAmend
{
	return _amend;
}


- (void)postIndexRefreshFinished
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexFinishedIndexRefresh object:self];
	});
}

// A multi-purpose notification sender for a refresh operation
// TODO: make -refresh take a completion handler, an NSError or *anything else*
- (void)postIndexRefreshSuccess:(BOOL)success message:(nullable NSString *)message
{
	void (^postNotification)(void) = ^{
		if (!success) {
			[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexRefreshFailed
																object:self
															  userInfo:@{@"description" : message}];
		} else {
			[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexRefreshStatus
																object:self
															  userInfo:@{@"description" : message}];
		}
	};
	if (NSThread.isMainThread)
		postNotification();
	else
		dispatch_async(dispatch_get_main_queue(), postNotification);
}

- (void)postIndexUpdated
{
	NSUInteger publishedGeneration = self.reconciledMutationGeneration;
	dispatch_async(dispatch_get_main_queue(), ^{
		BOOL wasPublishing = self.publishingSnapshot;
		self.publishingSnapshot = YES;
		[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexUpdated object:self];
		self.publishingSnapshot = wasPublishing;
		if (publishedGeneration == self.mutationGeneration && !self.postMutationStatCacheRefreshesPending) {
			self.mutationReconciliationPending = NO;
			NSLog(@"[GitX] Reconciled mutation %lu after publication %lu", (unsigned long)publishedGeneration, (unsigned long)self.snapshotRevision);
		}
	});
}

- (void)refresh
{
	if (self.closed) return;
	if (self.postMutationStatCacheRefreshesPending) {
		NSLog(@"[GitX] Deferred index refresh until %lu post-mutation stat-cache refreshes finish",
			  (unsigned long)self.postMutationStatCacheRefreshesPending);
		return;
	}
	[self.refreshCoordinator refreshBareRepository:self.repository.isBareRepository
										parentTree:self.parentTree
								mutationGeneration:self.mutationGeneration];
}

- (void)applyRefreshResult:(PBIndexRefreshResult *)result
{
	if (self.closed) return;
	if (result.mutationGeneration != self.mutationGeneration) {
		NSLog(@"[GitX] Discarded index refresh generation %lu before mutation generation %lu",
			  (unsigned long)result.mutationGeneration, (unsigned long)self.mutationGeneration);
		return;
	}
	BOOL wasPublishing = self.publishingSnapshot;
	self.publishingSnapshot = YES;
	self.reconciledMutationGeneration = result.mutationGeneration;
	self.snapshotRevision++;
	NSLog(@"[GitX] Accepted index publication %lu for mutation %lu", (unsigned long)self.snapshotRevision, (unsigned long)result.mutationGeneration);
	NSUInteger stagedCount = result.staged.count;
	NSUInteger unstagedCount = result.unstaged.count;
	NSUInteger untrackedCount = result.untracked.count;

	PBIndexFileReconciliation *reconciliation = [[PBIndexFileReconciliation alloc]
		initWithFiles:self.files
			   result:result
			  reducer:self.snapshotReducer];
	if (reconciliation.membershipChanged)
		[self willChangeValueForKey:@"indexChanges"];
	[self.files setArray:reconciliation.files];
	if (reconciliation.membershipChanged)
		[self didChangeValueForKey:@"indexChanges"];
	self.publishingSnapshot = wasPublishing;
	NSLog(@"[GitX] Merged index refresh snapshots: %lu staged, %lu unstaged, %lu untracked",
		  (unsigned long)stagedCount,
		  (unsigned long)unstagedCount,
		  (unsigned long)untrackedCount);

	[self postIndexUpdated];
}

// Refreshes the stat cache in the index by running git update-index --refresh.
// This clears phantom "modified" entries caused by stat mismatches (same content,
// different mtime). Called on app activation rather than every FSEvents notification
// to avoid holding index.lock constantly.
- (void)refreshStatCache
{
	if (self.closed) return;
	__weak PBGitIndex *weakSelf = self;
	[self.refreshCoordinator refreshStatCacheForBareRepository:self.repository.isBareRepository
													completion:^{
														[weakSelf refresh];
													}];
}

// Called after each Git mutation, including failures that may have changed an
// earlier chunk. Cached patches can leave matching content with stale index stat
// metadata, so no refresh may publish this generation until cache work finishes.
- (void)reconcileAfterMutation
{
	if (self.repository.isBareRepository) {
		// The stat-cache API deliberately has no callback for bare repositories.
		self.postMutationStatCacheRefreshesPending--;
		[self refresh];
		return;
	}
	NSLog(@"[GitX] Refreshing index stat cache before reconciling mutation generation %lu",
		  (unsigned long)self.mutationGeneration);
	__weak PBGitIndex *weakSelf = self;
	[self.refreshCoordinator refreshStatCacheForBareRepository:NO
													completion:^{
														PBGitIndex *strongSelf = weakSelf;
														if (!strongSelf) return;
														strongSelf.postMutationStatCacheRefreshesPending--;
														NSLog(@"[GitX] Finished post-mutation stat-cache refresh (%lu remaining)",
															  (unsigned long)strongSelf.postMutationStatCacheRefreshesPending);
														// Errors still complete this callback. Retain normal snapshot failure
														// handling, and fan out once for the latest mutation after all caches.
														if (!strongSelf.postMutationStatCacheRefreshesPending)
															[strongSelf refresh];
													}];
}

// Returns the tree to compare the index to, based
// on whether amend is set or not.
- (NSString *)parentTree
{
	NSString *parent = self.amend ? @"HEAD^" : @"HEAD";

	if (![self.repository revisionExists:parent])
		// We don't have a head ref. Return the empty tree.
		return @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

	return parent;
}

- (NSString *)createPrepareCommitMessage
{
	NSString *headSHA = nil;
	NSString *existingMessage = nil;
	if (self.amend) {
		headSHA = self.repository.headOID.SHA;
		GTReference *headRef = [self.repository.gtRepo headReferenceWithError:NULL];
		GTCommit *commit = [headRef resolvedTarget];
		existingMessage = commit.message;
	}

	NSError *error = nil;
	NSString *message = [self.commitService prepareCommitMessageForAmend:self.amend
																 headSHA:headSHA
														 existingMessage:existingMessage
																   error:&error];
	if (!message && [error.domain isEqualToString:@"PBGitIndexCommitError"])
		[self postCommitHookFailure:error.localizedDescription];
	return message;
}

- (void)commitWithMessage:(NSString *)commitMessage andVerify:(BOOL)doVerify
{
	if (self.closed || self.submissionActive || self.mutationReconciliationPending) {
		[self postCommitUpdate:@"A commit is already in progress or the index is refreshing."];
		return;
	}
	NSError *error = nil;
	GTConfiguration *config = [self.repository.gtRepo configurationWithError:&error];
	if (!config) {
		PBLogError(error);
		[self postCommitFailure:@"Failed to load repository configuration"];
		return;
	}

	BOOL gpgSign = [config boolForKey:@"commit.gpgSign"];
	PBIndexCommitRequest *request = [[PBIndexCommitRequest alloc] initWithMessage:commitMessage
																		   verify:doVerify
																		  gpgSign:gpgSign
																			amend:self.amend
																	  environment:self.amendEnvironment
																	   parentSHAs:@[]
																		  hasHead:NO];
	self.retainedCommitRequest = request;
	self.submissionActive = YES;
	[self submitCommitRequest:request];
}

- (void)submitCommitRequest:(PBIndexCommitRequest *)request
{
	self.awaitingHookDecision = NO;
	NSLog(@"[GitX] Scheduling interactive commit orchestration");
	__weak PBGitIndex *weakSelf = self;
	[self.commitCoordinator commitWithRequest:request
								 eventHandler:^(PBIndexCommitEvent *event) {
									 PBGitIndex *strongSelf = weakSelf;
									 if (!strongSelf)
										 return;
									 NSAssert(NSThread.isMainThread, @"Commit events must be delivered on the main thread");
									 if ([event isKindOfClass:PBIndexCommitPreparedEvent.class]) {
										 strongSelf.retainedCommitRequest = ((PBIndexCommitPreparedEvent *)event).request;
										 NSLog(@"[GitX] Retained freshly prepared HEAD expectation and commit parents");
									 } else if ([event isKindOfClass:PBIndexCommitPhaseEvent.class]) {
										 PBIndexCommitPhaseEvent *phaseEvent = (PBIndexCommitPhaseEvent *)event;
										 [strongSelf postCommitUpdate:phaseEvent.displayName phase:phaseEvent.phase];
									 } else if ([event isKindOfClass:PBIndexCommitOutputEvent.class]) {
										 [strongSelf postCommitOutput:((PBIndexCommitOutputEvent *)event).output];
									 } else if ([event isKindOfClass:PBIndexCommitCompletionEvent.class]) {
										 [strongSelf handleCommitResult:((PBIndexCommitCompletionEvent *)event).result];
									 }
								 }];
}

- (void)handleCommitResult:(PBIndexCommitResult *)result
{
	NSAssert(NSThread.isMainThread, @"Commit completion must be handled on the main thread");
	NSLog(@"[GitX] Handling interactive commit completion (kind: %ld)", (long)result.kind);
	if (result.kind == PBIndexCommitResultKindFailure) {
		self.mutationGeneration++;
		self.postMutationStatCacheRefreshesPending++;
		self.mutationReconciliationPending = YES;
		[self endCommitSubmission];
		[self reconcileAfterMutation];
		[self postCommitFailure:result.message];
		return;
	}
	if (result.kind == PBIndexCommitResultKindHookFailure) {
		self.awaitingHookDecision = YES;
		NSLog(@"[GitX] Retained commit request while awaiting hook decision");
		[self postCommitHookFailure:result.message];
		return;
	}
	// The commit exists even if the post-commit hook failed. Keep mutation
	// controls disabled until Git reports the authoritative new index state.
	self.mutationGeneration++;
	self.postMutationStatCacheRefreshesPending++;
	self.mutationReconciliationPending = YES;
	[self endCommitSubmission];

	NSDictionary *userInfo = @{
		@"success" : @(result.postCommitHookSucceeded),
		@"description" : result.message,
		@"sha" : result.sha ?: @"",
	};

	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexFinishedCommit
														object:self
													  userInfo:userInfo];
	self.repository.hasChanged = YES;

	self.amendEnvironment = nil;
	if (self.amend)
		self.amend = NO;
	[self reconcileAfterMutation];
}

- (void)retryCommitWithoutVerification
{
	if (!self.submissionActive || !self.awaitingHookDecision || !self.retainedCommitRequest) return;
	NSLog(@"[GitX] Retrying immutable commit request without verification");
	[self submitCommitRequest:[self.retainedCommitRequest requestWithoutVerification]];
}

- (void)cancelCommitSubmission
{
	[self.retainedCommitRequest cancel];
	if (self.submissionActive && !self.awaitingHookDecision) {
		// Keep admission closed until the owned worker has aborted and completed.
		NSLog(@"[GitX] Requested cancellation of the active commit worker");
		return;
	}
	[self endCommitSubmission];
}

- (void)endCommitSubmission
{
	BOOL reconcileHookChanges = self.awaitingHookDecision;
	if (reconcileHookChanges) {
		self.mutationGeneration++;
		self.postMutationStatCacheRefreshesPending++;
		self.mutationReconciliationPending = YES;
	}
	NSLog(@"[GitX] Ended commit submission");
	self.retainedCommitRequest = nil;
	self.awaitingHookDecision = NO;
	self.submissionActive = NO;
	if (reconcileHookChanges) [self reconcileAfterMutation];
}

- (void)postCommitUpdate:(NSString *)update
{
	[self postCommitUpdate:update phase:PBIndexCommitPhaseCreatingTree];
}

- (void)postCommitUpdate:(NSString *)update phase:(PBIndexCommitPhase)phase
{
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexCommitStatus
														object:self
													  userInfo:@{
														  @"description" : update,
														  @"phase" : @(phase),
													  }];
}

- (void)postCommitOutput:(NSString *)output
{
	if (output.length == 0)
		return;
	NSLog(@"[GitX] Posting %lu characters of interactive commit output", (unsigned long)output.length);
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexCommitOutput
														object:self
													  userInfo:@{
														  @"description" : output,
														  @"output" : output,
													  }];
}

- (void)postCommitFailure:(NSString *)reason
{
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexCommitFailed
														object:self
													  userInfo:[NSDictionary dictionaryWithObject:reason forKey:@"description"]];
}

- (void)postCommitHookFailure:(NSString *)reason
{
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexCommitHookFailed
														object:self
													  userInfo:[NSDictionary dictionaryWithObject:reason forKey:@"description"]];
}

- (void)postOperationFailed:(NSString *)description
{
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexOperationFailed
														object:self
													  userInfo:[NSDictionary dictionaryWithObject:description forKey:@"description"]];
}

- (void)close
{
	self.closed = YES;
	[self.mutationCoordinator close];
	[self cancelCommitSubmission];
}

- (BOOL)scheduleMutation:(PBIndexMutationRequest *)request operation:(NSString *)operation completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	if (self.closed) return NO;
	self.mutationGeneration++;
	self.postMutationStatCacheRefreshesPending++;
	self.mutationReconciliationPending = YES;
	__weak PBGitIndex *weakSelf = self;
	BOOL admitted = [self.mutationCoordinator scheduleRequest:request
												   completion:^(BOOL success, NSError *error) {
													   PBGitIndex *index = weakSelf;
													   if (index && !index.closed) {
														   [index reconcileAfterMutation];
														   if (!success) [index postOperationFailed:[PBIndexOperationErrorPresentation messageForOperation:operation error:error]];
													   }
													   completion(success, error);
												   }];
	if (!admitted) {
		self.postMutationStatCacheRefreshesPending--;
		self.mutationReconciliationPending = self.postMutationStatCacheRefreshesPending != 0;
	}
	return admitted;
}

- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)files completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	return [self stageFiles:files unstageFiles:@[] completion:completion];
}

- (BOOL)unstageFiles:(NSArray<PBChangedFile *> *)files completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	return [self stageFiles:@[] unstageFiles:files completion:completion];
}

- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	if (self.closed) return NO;
	if (!stageFiles.count && !unstageFiles.count) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(YES, nil);
		});
		return !self.closed;
	}
	PBIndexMutationRequest *request = [[PBIndexMutationRequest alloc] initWithStagePaths:[stageFiles valueForKey:@"rawPath"] unstagePaths:[unstageFiles valueForKey:@"rawPath"] parentTree:self.parentTree];
	return [self scheduleMutation:request operation:@"Staging and unstaging files failed" completion:completion];
}

- (BOOL)discardChangesForFiles:(NSArray<PBChangedFile *> *)files completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	if (self.closed) return NO;
	NSArray<PBChangedFile *> *tracked = [PBIndexFilePresentation discardableFilesFromFiles:files];
	if (!tracked.count) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(YES, nil);
		});
		return !self.closed;
	}
	return [self scheduleMutation:[[PBIndexMutationRequest alloc] initWithDiscardPaths:[tracked valueForKey:@"rawPath"]] operation:@"Discarding changes failed" completion:completion];
}

- (BOOL)applyPatch:(NSString *)patch stage:(BOOL)stage reverse:(BOOL)reverse completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	return [self scheduleMutation:[[PBIndexMutationRequest alloc] initWithPatch:patch stage:stage reverse:reverse] operation:@"Applying patch failed" completion:completion];
}

- (BOOL)applyPatch:(NSString *)patch stage:(BOOL)stage reverse:(BOOL)reverse authorization:(PBIndexPatchAuthorization *)authorization completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	return [self scheduleMutation:[[PBIndexMutationRequest alloc] initWithPatch:patch stage:stage reverse:reverse authorization:authorization] operation:@"Applying patch failed" completion:completion];
}

- (BOOL)discardChangesForFiles:(NSArray<PBChangedFile *> *)files authorization:(PBIndexPatchAuthorization *)authorization completion:(void (^)(BOOL, NSError *_Nullable))completion
{
	NSArray<PBChangedFile *> *tracked = [PBIndexFilePresentation discardableFilesFromFiles:files];
	return [self scheduleMutation:[[PBIndexMutationRequest alloc] initWithDiscardPaths:[tracked valueForKey:@"rawPath"] authorization:authorization] operation:@"Discarding changes failed" completion:completion];
}

- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles
{
	return [self stageFiles:stageFiles unstageFiles:@[]];
}

- (BOOL)unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles
{
	return [self stageFiles:@[] unstageFiles:unstageFiles];
}

- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles
{
	if (self.closed) return NO;
	if (!stageFiles.count && !unstageFiles.count) return YES;
	self.mutationGeneration++;
	self.postMutationStatCacheRefreshesPending++;
	self.mutationReconciliationPending = YES;
	NSError *error = nil;
	BOOL success = [self.mutationService stageRawPaths:[stageFiles valueForKey:@"rawPath"]
									   unstageRawPaths:[unstageFiles valueForKey:@"rawPath"]
											parentTree:self.parentTree
												 error:&error];
	[self reconcileAfterMutation];
	if (!success) {
		NSString *operation = stageFiles.count && unstageFiles.count ? @"Staging and unstaging files failed" : (stageFiles.count ? @"Staging files failed" : @"Unstaging files failed");
		[self postOperationFailed:[PBIndexOperationErrorPresentation messageForOperation:operation error:error]];
	}
	return success;
}

- (void)discardChangesForFiles:(NSArray<PBChangedFile *> *)discardFiles
{
	if (self.closed) return;
	NSArray<PBChangedFile *> *trackedFiles = [PBIndexFilePresentation discardableFilesFromFiles:discardFiles];
	if (!trackedFiles.count) return;
	self.mutationGeneration++;
	self.postMutationStatCacheRefreshesPending++;
	self.mutationReconciliationPending = YES;
	NSArray<NSData *> *paths = [trackedFiles valueForKey:@"rawPath"];
	NSError *error = nil;
	BOOL success = [self.mutationService discardRawPaths:paths error:&error];
	[self reconcileAfterMutation];
	if (!success) {
		[self postOperationFailed:[PBIndexOperationErrorPresentation messageForOperation:@"Discarding changes failed" error:error]];
		return;
	}
}

- (BOOL)applyPatch:(NSString *)hunk stage:(BOOL)stage reverse:(BOOL)reverse;
{
	if (self.closed) return NO;
	self.mutationGeneration++;
	self.postMutationStatCacheRefreshesPending++;
	self.mutationReconciliationPending = YES;
	NSError *error = nil;
	if (![self.mutationService applyPatch:hunk stage:stage reverse:reverse error:&error]) {
		NSString *message = [PBIndexOperationErrorPresentation messageForOperation:@"Applying patch failed" error:error];
		[self postOperationFailed:message];
		[self reconcileAfterMutation];
		return NO;
	}

	// TODO: Try to be smarter about what to refresh
	[self reconcileAfterMutation];
	return YES;
}


- (nullable NSString *)diffForFile:(PBChangedFile *)file staged:(BOOL)staged contextLines:(NSUInteger)context
{
	return [self diffForFile:file staged:staged contextLines:context ignoreWhitespace:NO];
}

- (nullable NSArray<NSString *> *)diffToolArgumentsForFile:(PBChangedFile *)file staged:(BOOL)staged error:(NSError *_Nullable *_Nullable)error
{
	return [self.mutationService diffToolArgumentsForRawPath:file.rawPath staged:staged error:error];
}

- (nullable NSArray<NSString *> *)literalArgumentsForRawPath:(NSData *)rawPath commandArguments:(NSArray<NSString *> *)commandArguments error:(NSError *_Nullable *_Nullable)error
{
	return [self.mutationService literalArgumentsForRawPath:rawPath commandArguments:commandArguments error:error];
}

- (nullable NSString *)diffForFile:(PBChangedFile *)file staged:(BOOL)staged contextLines:(NSUInteger)context ignoreWhitespace:(BOOL)ignoreWhitespace
{
	NSError *error = nil;
	NSString *output = [self.mutationService diffForRawPath:file.rawPath
												displayPath:file.path
													 status:(staged ? file.stagedStatus : file.worktreeStatus)
															hasStagedChanges:file.hasStagedChanges
													 staged:staged
												 parentTree:self.parentTree
											   contextLines:context
										   ignoreWhitespace:ignoreWhitespace
													  error:&error];
	if (!output)
		PBLogError(error);
	return output;
}

@end

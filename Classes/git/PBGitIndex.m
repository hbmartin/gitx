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
@property (retain) PBIndexCommitService *commitService;
@property (retain) PBIndexCommitCoordinator *commitCoordinator;
@property (retain) PBIndexRefreshCoordinator *refreshCoordinator;
@property (readwrite) BOOL mutationReconciliationPending;
@property NSUInteger mutationGeneration;
@property NSUInteger reconciledMutationGeneration;
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
		if (self.reconciledMutationGeneration == self.mutationGeneration)
			self.mutationReconciliationPending = NO;
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
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexUpdated object:self];
	});
}

- (void)refresh
{
	[self.refreshCoordinator refreshBareRepository:self.repository.isBareRepository
										parentTree:self.parentTree
								mutationGeneration:self.mutationGeneration];
}

- (void)applyRefreshResult:(PBIndexRefreshResult *)result
{
	if (result.mutationGeneration != self.mutationGeneration) {
		NSLog(@"[GitX] Discarded index refresh generation %lu before mutation generation %lu",
			  (unsigned long)result.mutationGeneration, (unsigned long)self.mutationGeneration);
		return;
	}
	self.reconciledMutationGeneration = result.mutationGeneration;
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
	__weak PBGitIndex *weakSelf = self;
	[self.refreshCoordinator refreshStatCacheForBareRepository:self.repository.isBareRepository
													completion:^{
														[weakSelf refresh];
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
	NSError *error = nil;
	GTConfiguration *config = [self.repository.gtRepo configurationWithError:&error];
	if (!config) {
		PBLogError(error);
		[self postCommitFailure:@"Failed to load repository configuration"];
		return;
	}

	NSMutableArray<NSString *> *parentSHAs = [NSMutableArray array];
	if (self.amend) {
		GTReference *headRef = [self.repository.gtRepo headReferenceWithError:NULL];
		GTCommit *headCommit = [headRef resolvedTarget];
		NSLog(@"[GitX] Amending commit with %lu preserved parent(s)", (unsigned long)headCommit.parentOIDs.count);
		for (GTOID *parentOID in headCommit.parentOIDs)
			[parentSHAs addObject:parentOID.SHA];
	}

	BOOL gpgSign = [config boolForKey:@"commit.gpgSign"];
	PBIndexCommitRequest *request = [[PBIndexCommitRequest alloc] initWithMessage:commitMessage
																		   verify:doVerify
																		  gpgSign:gpgSign
																			amend:self.amend
																	  environment:self.amendEnvironment
																	   parentSHAs:parentSHAs
																		  hasHead:[self.repository revisionExists:@"HEAD"]];
	NSLog(@"[GitX] Scheduling interactive commit orchestration");
	__weak PBGitIndex *weakSelf = self;
	[self.commitCoordinator commitWithRequest:request
								 eventHandler:^(PBIndexCommitEvent *event) {
									 PBGitIndex *strongSelf = weakSelf;
									 if (!strongSelf)
										 return;
									 NSAssert(NSThread.isMainThread, @"Commit events must be delivered on the main thread");
									 if ([event isKindOfClass:PBIndexCommitPhaseEvent.class]) {
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
		[self postCommitFailure:result.message];
		return;
	}
	if (result.kind == PBIndexCommitResultKindHookFailure) {
		[self postCommitHookFailure:result.message];
		return;
	}
	// The commit exists even if the post-commit hook failed. Keep mutation
	// controls disabled until Git reports the authoritative new index state.
	self.mutationGeneration++;
	self.mutationReconciliationPending = YES;

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
	else
		[self refresh];
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

- (BOOL)performStageOrUnstage:(BOOL)stage withFiles:(NSArray *)files
{
	if (!files.count) return YES;
	self.mutationGeneration++;
	self.mutationReconciliationPending = YES;
	NSArray<NSData *> *paths = [files valueForKey:@"rawPath"];
	NSError *error = nil;
	BOOL success = stage ? [self.mutationService stageRawPaths:paths error:&error] : [self.mutationService unstageRawPaths:paths parentTree:self.parentTree error:&error];
	// A preceding chunk may have succeeded even if this call reports failure.
	[self refresh];
	if (!success) {
		[self postOperationFailed:[PBIndexOperationErrorPresentation messageForOperation:(stage ? @"Staging files failed" : @"Unstaging files failed") error:error]];
		return NO;
	}
	return YES;
}

- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles
{
	return [self performStageOrUnstage:YES withFiles:stageFiles];
}

- (BOOL)unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles
{
	return [self performStageOrUnstage:NO withFiles:unstageFiles];
}

- (void)discardChangesForFiles:(NSArray<PBChangedFile *> *)discardFiles
{
	NSArray<PBChangedFile *> *trackedFiles = [PBIndexFilePresentation discardableFilesFromFiles:discardFiles];
	if (!trackedFiles.count) return;
	self.mutationGeneration++;
	self.mutationReconciliationPending = YES;
	NSArray<NSData *> *paths = [trackedFiles valueForKey:@"rawPath"];
	NSError *error = nil;
	BOOL success = [self.mutationService discardRawPaths:paths error:&error];
	[self refresh];
	if (!success) {
		[self postOperationFailed:[PBIndexOperationErrorPresentation messageForOperation:@"Discarding changes failed" error:error]];
		return;
	}
}

- (BOOL)applyPatch:(NSString *)hunk stage:(BOOL)stage reverse:(BOOL)reverse;
{
	self.mutationGeneration++;
	self.mutationReconciliationPending = YES;
	NSError *error = nil;
	if (![self.mutationService applyPatch:hunk stage:stage reverse:reverse error:&error]) {
		NSString *message = [PBIndexOperationErrorPresentation messageForOperation:@"Applying patch failed" error:error];
		[self postOperationFailed:message];
		[self refresh];
		return NO;
	}

	// TODO: Try to be smarter about what to refresh
	[self refresh];
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

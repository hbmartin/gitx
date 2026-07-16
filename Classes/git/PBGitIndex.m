//
//  PBGitIndex.m
//  GitX
//
//  Created by Pieter de Bie on 9/12/09.
//  Copyright 2009 Pieter de Bie. All rights reserved.
//

#import "PBGitIndex.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitBinary.h"
#import "PBTask.h"
#import "PBChangedFile.h"
#import "GitX-Swift.h"

NSString *PBGitIndexIndexRefreshStatus = @"PBGitIndexIndexRefreshStatus";
NSString *PBGitIndexIndexRefreshFailed = @"PBGitIndexIndexRefreshFailed";
NSString *PBGitIndexFinishedIndexRefresh = @"PBGitIndexFinishedIndexRefresh";

NSString *PBGitIndexIndexUpdated = @"PBGitIndexIndexUpdated";

NSString *PBGitIndexCommitStatus = @"PBGitIndexCommitStatus";
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
	dispatch_queue_t _indexRefreshQueue;
	dispatch_group_t _indexRefreshGroup;
	BOOL _amend;
	BOOL _refreshInProgress;
	BOOL _refreshPending;
}

@property (retain) NSDictionary *amendEnvironment;
@property (retain) NSMutableArray<PBChangedFile *> *files;
@property (retain) PBIndexStatusParser *statusParser;
@property (retain) PBIndexSnapshotReducer *snapshotReducer;
@property (retain) PBIndexMutationService *mutationService;
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

	_indexRefreshGroup = dispatch_group_create();
	_indexRefreshQueue = dispatch_queue_create("org.gitx.indexRefresh", DISPATCH_QUEUE_SERIAL);

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

	[self refresh];

	if (!newAmend)
		return;

	// If we amend, we want to keep the author information for the previous commit
	// We do this by reading in the previous commit, and storing the information
	// in a dictionary. This dictionary will then later be read by [self commit:]
	GTReference *headRef = [self.repository.gtRepo headReferenceWithError:NULL];
	GTCommit *commit = [headRef resolvedTarget];
	if (commit)
		self.amendEnvironment = @{
			@"GIT_AUTHOR_NAME" : commit.author.name,
			@"GIT_AUTHOR_EMAIL" : commit.author.email,
			@"GIT_AUTHOR_DATE" : commit.commitDate,
		};

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
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!success) {
			[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexRefreshFailed
																object:self
															  userInfo:@{@"description" : message}];
		} else {
			[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexRefreshStatus
																object:self
															  userInfo:@{@"description" : message}];
		}
	});
}

- (void)postIndexUpdated
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexIndexUpdated object:self];
	});
}

- (void)refresh
{
	//
	// Guard against concurrent refresh calls — skip if one is already running
	__block BOOL shouldSkip = NO;
	dispatch_sync(_indexRefreshQueue, ^{
		if (self->_refreshInProgress) {
			self->_refreshPending = YES;
			shouldSkip = YES;
			return;
		}
		self->_refreshInProgress = YES;
	});

	if (shouldSkip) {
		return;
	}

	__block NSDictionary<NSString *, PBIndexStatusEntry *> *untrackedDictionary = nil;
	__block NSDictionary<NSString *, PBIndexStatusEntry *> *stagedDictionary = nil;
	__block NSDictionary<NSString *, PBIndexStatusEntry *> *unstagedDictionary = nil;

	// Enter the group for ALL tasks upfront, before launching any of them.
	// This prevents dispatch_group_notify from firing prematurely if an
	// early task completes before later tasks have called group_enter.
	BOOL isBare = [self.repository isBareRepository];
	if (!isBare) {
		dispatch_group_enter(_indexRefreshGroup); // ls-files
		dispatch_group_enter(_indexRefreshGroup); // diff-index
		dispatch_group_enter(_indexRefreshGroup); // diff-files
	}

	// Register the notify block AFTER all group_enter calls.
	// This block runs once all tasks have called group_leave.
	dispatch_group_notify(_indexRefreshGroup, dispatch_get_main_queue(), ^{
		// At this point, all index operations have finished.
		// Merge the three snapshots in Git-semantic order. The staged snapshot
		// owns the parent-tree metadata used by whole-file unstage; the unstaged
		// snapshot must not replace it with the current index entry.
		NSUInteger stagedCount = stagedDictionary.count;
		NSUInteger unstagedCount = unstagedDictionary.count;
		NSUInteger untrackedCount = untrackedDictionary.count;

		NSMutableArray<PBIndexFileSnapshot *> *previous = [NSMutableArray arrayWithCapacity:self.files.count];
		for (PBChangedFile *file in self.files) {
			[previous addObject:[[PBIndexFileSnapshot alloc] initWithPath:file.path
																   status:file.status
														   commitBlobMode:file.commitBlobMode
															commitBlobSHA:file.commitBlobSHA
														 hasStagedChanges:file.hasStagedChanges
													   hasUnstagedChanges:file.hasUnstagedChanges]];
		}
		NSArray<PBIndexFileSnapshot *> *snapshots = [self.snapshotReducer reducePrevious:previous
																				  staged:stagedDictionary
																				unstaged:unstagedDictionary
																			   untracked:untrackedDictionary];
		NSMutableDictionary<NSString *, PBChangedFile *> *existing = [NSMutableDictionary dictionaryWithCapacity:self.files.count];
		for (PBChangedFile *file in self.files)
			existing[file.path] = file;
		NSMutableArray<PBChangedFile *> *reconciled = [NSMutableArray arrayWithCapacity:snapshots.count];
		BOOL membershipChanged = snapshots.count != self.files.count;
		for (PBIndexFileSnapshot *snapshot in snapshots) {
			PBChangedFile *file = existing[snapshot.path];
			if (!file) {
				file = [[PBChangedFile alloc] initWithPath:snapshot.path];
				membershipChanged = YES;
			}
			file.status = (PBChangedFileStatus)snapshot.status;
			file.commitBlobMode = snapshot.commitBlobMode;
			file.commitBlobSHA = snapshot.commitBlobSHA;
			file.hasStagedChanges = snapshot.hasStagedChanges;
			file.hasUnstagedChanges = snapshot.hasUnstagedChanges;
			[reconciled addObject:file];
		}
		if (membershipChanged)
			[self willChangeValueForKey:@"indexChanges"];
		[self.files setArray:reconciled];
		if (membershipChanged)
			[self didChangeValueForKey:@"indexChanges"];
		NSLog(@"[GitX] Merged index refresh snapshots: %lu staged, %lu unstaged, %lu untracked",
			  (unsigned long)stagedCount,
			  (unsigned long)unstagedCount,
			  (unsigned long)untrackedCount);

		[self postIndexUpdated];

		__block BOOL shouldReplay = NO;
		dispatch_sync(self->_indexRefreshQueue, ^{
			self->_refreshInProgress = NO;
			shouldReplay = self->_refreshPending;
			self->_refreshPending = NO;
		});

		if (shouldReplay) {
			[self refresh];
		} else {
			[self postIndexRefreshFinished];
		}
	});

	if (isBare) {
		return;
	}

	// Other files (untracked)
	[PBTask launchTask:[PBGitBinary path]
				arguments:@[ @"ls-files", @"--others", @"--exclude-standard", @"-z" ]
			  inDirectory:self.repository.workingDirectoryURL.path
		completionHandler:^(NSData *readData, NSError *error) {
			// Serialize access to self.files via _indexRefreshQueue
			dispatch_async(self->_indexRefreshQueue, ^{
				if (error) {
					[self postIndexRefreshSuccess:NO message:@"ls-files failed"];
				} else {
					NSError *parseError = nil;
					untrackedDictionary = [self.statusParser parseUntrackedData:readData error:&parseError];
					[self postIndexRefreshSuccess:untrackedDictionary != nil
										  message:untrackedDictionary ? @"ls-files success" : @"ls-files failed"];
				}

				dispatch_group_leave(self->_indexRefreshGroup);
			});
		}];

	// Staged files
	[PBTask launchTask:[PBGitBinary path]
				arguments:@[ @"diff-index", @"--cached", @"-z", [self parentTree] ]
			  inDirectory:self.repository.workingDirectoryURL.path
		completionHandler:^(NSData *readData, NSError *error) {
			// Serialize access to self.files via _indexRefreshQueue
			dispatch_async(self->_indexRefreshQueue, ^{
				if (error) {
					[self postIndexRefreshSuccess:NO message:@"diff-index failed"];
				} else {
					NSError *parseError = nil;
					stagedDictionary = [self.statusParser parseTrackedData:readData error:&parseError];
					[self postIndexRefreshSuccess:stagedDictionary != nil
										  message:stagedDictionary ? @"diff-index success" : @"diff-index failed"];
				}

				dispatch_group_leave(self->_indexRefreshGroup);
			});
		}];

	// Unstaged files
	[PBTask launchTask:[PBGitBinary path]
				arguments:@[ @"diff-files", @"-z" ]
			  inDirectory:self.repository.workingDirectoryURL.path
		completionHandler:^(NSData *readData, NSError *error) {
			// Serialize access to self.files via _indexRefreshQueue
			dispatch_async(self->_indexRefreshQueue, ^{
				if (error) {
					[self postIndexRefreshSuccess:NO message:@"diff-files failed"];
				} else {
					NSError *parseError = nil;
					unstagedDictionary = [self.statusParser parseTrackedData:readData error:&parseError];
					[self postIndexRefreshSuccess:unstagedDictionary != nil
										  message:unstagedDictionary ? @"diff-files success" : @"diff-files failed"];
				}

				dispatch_group_leave(self->_indexRefreshGroup);
			});
		}];
}

// Refreshes the stat cache in the index by running git update-index --refresh.
// This clears phantom "modified" entries caused by stat mismatches (same content,
// different mtime). Called on app activation rather than every FSEvents notification
// to avoid holding index.lock constantly.
- (void)refreshStatCache
{
	if ([self.repository isBareRepository]) return;

	[PBTask launchTask:[PBGitBinary path]
				arguments:@[ @"update-index", @"-q", @"--unmerged", @"--ignore-missing", @"--refresh" ]
			  inDirectory:self.repository.workingDirectoryURL.path
		completionHandler:^(NSData *readData, NSError *error) {
			[self refresh];
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
	NSError *error;
	NSString *messagePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"commit-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
	NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObject:messagePath];
	PBGitRepository *repository = [self repository];

	if ([[repository index] isAmend]) {
		// git itself seems to pass HEAD when doing a plain 'git commit --amend', but git's documentation says the third argument can be a commit hash
		[arguments addObject:@"commit"];
		[arguments addObject:self.repository.headOID.SHA];

		// Write the message of the commit we're amending to a file so we can run the prepare-commit-msg hook on it
		GTReference *headRef = [self.repository.gtRepo headReferenceWithError:NULL];
		GTCommit *commit = [headRef resolvedTarget];

		[commit.message writeToFile:messagePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	}

	NSString *prepareCommitMessage;

	if ([repository executeHook:@"prepare-commit-msg" arguments:arguments error:&error]) {
		prepareCommitMessage = [NSString stringWithContentsOfFile:messagePath usedEncoding:NULL error:&error];

		// Trim the last newline from the string (to make this match how git presents the results)
		if ([prepareCommitMessage length] > 0 && [prepareCommitMessage characterAtIndex:[prepareCommitMessage length] - 1] == '\n') {
			prepareCommitMessage = [prepareCommitMessage substringToIndex:[prepareCommitMessage length] - 1];
		}

		[[NSFileManager defaultManager] removeItemAtPath:messagePath error:NULL];
	} else {
		NSError *taskError = error.userInfo[NSUnderlyingErrorKey];
		NSString *hookOutput = taskError.userInfo[PBTaskTerminationOutputKey];
		NSString *hookFailureMessage = [NSString stringWithFormat:@"prepare-commit-msg hook failed%@%@",
																  hookOutput && [hookOutput length] > 0 ? @":\n" : @"",
																  hookOutput];

		[self postCommitHookFailure:hookFailureMessage];
	}

	return prepareCommitMessage;
}

// TODO: make Asynchronous
- (void)commitWithMessage:(NSString *)commitMessage andVerify:(BOOL)doVerify
{
	NSError *error = nil;
	GTConfiguration *config = [self.repository.gtRepo configurationWithError:&error];
	if (!config) {
		PBLogError(error);
		[self postCommitFailure:@"Failed to load repository configuration"];
		return;
	}

	NSMutableString *commitSubject = [@"commit: " mutableCopy];
	NSRange newLine = [commitMessage rangeOfString:@"\n"];
	if (newLine.location == NSNotFound)
		[commitSubject appendString:commitMessage];
	else
		[commitSubject appendString:[commitMessage substringToIndex:newLine.location]];

	NSString *commitMessageFile;
	commitMessageFile = [self.repository.gitURL.path stringByAppendingPathComponent:@"COMMIT_EDITMSG"];

	[commitMessage writeToFile:commitMessageFile atomically:YES encoding:NSUTF8StringEncoding error:nil];


	[self postCommitUpdate:@"Creating tree"];
	NSString *tree = [self.repository outputOfTaskWithArguments:@[ @"write-tree" ] error:&error];
	if (!tree) {
		PBLogError(error);
		return [self postCommitFailure:@"Failed to lookup tree"];
	}
	tree = [tree stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([tree length] != 40)
		return [self postCommitFailure:@"Creating tree failed"];


	NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"commit-tree", tree, nil];
	if (self.amend) {
		GTReference *headRef = [self.repository.gtRepo headReferenceWithError:NULL];
		GTCommit *headCommit = [headRef resolvedTarget];
		NSLog(@"[GitX] Amending commit with %lu preserved parent(s)", (unsigned long)headCommit.parentOIDs.count);
		for (GTOID *parentOID in headCommit.parentOIDs) {
			[arguments addObject:@"-p"];
			[arguments addObject:parentOID.SHA];
		}
	} else if ([self.repository revisionExists:@"HEAD"]) {
		[arguments addObject:@"-p"];
		[arguments addObject:@"HEAD"];
	}

	BOOL gpgSign = [config boolForKey:@"commit.gpgSign"];
	if (gpgSign) {
		[arguments addObject:@"--gpg-sign"];
	}

	[self postCommitUpdate:@"Creating commit"];

	if (doVerify) {
		[self postCommitUpdate:@"Running hooks"];
		NSString *hookFailureMessage = nil;
		NSError *error = nil;
		BOOL success = [self.repository executeHook:@"pre-commit" error:&error];
		if (!success) {
			NSError *taskError = error.userInfo[NSUnderlyingErrorKey];
			NSString *hookOutput = taskError.userInfo[PBTaskTerminationOutputKey];
			hookFailureMessage = [NSString stringWithFormat:@"Pre-commit hook failed%@%@",
															hookOutput && [hookOutput length] > 0 ? @":\n" : @"",
															hookOutput];
			[self postCommitHookFailure:hookFailureMessage];
			return;
		}

		success = [self.repository executeHook:@"commit-msg" arguments:@[ commitMessageFile ] error:&error];
		if (!success) {
			NSError *taskError = error.userInfo[NSUnderlyingErrorKey];
			NSString *hookOutput = taskError.userInfo[PBTaskTerminationOutputKey];
			hookFailureMessage = [NSString stringWithFormat:@"Commit-msg hook failed%@%@",
															hookOutput && [hookOutput length] > 0 ? @":\n" : @"",
															hookOutput];
			[self postCommitHookFailure:hookFailureMessage];
			return;
		}
	}

	commitMessage = [NSString stringWithContentsOfFile:commitMessageFile encoding:NSUTF8StringEncoding error:nil];

	PBTask *task = [self.repository taskWithArguments:arguments];
	task.additionalEnvironment = self.amendEnvironment;
	task.standardInputData = [commitMessage dataUsingEncoding:NSUTF8StringEncoding];

	BOOL success = [task launchTask:&error];
	NSString *commit = [[task standardOutputString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (!success || commit.length != 40) {
		PBLogError(error);
		NSString *taskOutput = error.userInfo[PBTaskTerminationOutputKey];
		if (gpgSign && [taskOutput hasPrefix:@"error: cannot run gpg"]) {
			[self postCommitFailure:@"GPG signing seems to have failed.\n\nMake sure you have configured your environment correctly and have set gpg.program to point at your gpg binary."];
		} else {
			[self postCommitFailure:@"Could not create a commit object"];
		}
		return;
	}

	[self postCommitUpdate:@"Updating HEAD"];
	success = [self.repository launchTaskWithArguments:@[ @"update-ref", @"-m", commitSubject, @"HEAD", commit ] error:&error];
	if (!success) {
		PBLogError(error);
		return [self postCommitFailure:@"Could not update HEAD"];
	}

	[self postCommitUpdate:@"Running post-commit hook"];

	success = [self.repository executeHook:@"post-commit" error:NULL];
	NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithBool:success] forKey:@"success"];
	NSString *description;
	if (success)
		description = [NSString stringWithFormat:@"Successfully created commit %@", commit];
	else
		description = [NSString stringWithFormat:@"Post-commit hook failed, but successfully created commit %@", commit];

	[userInfo setObject:description forKey:@"description"];
	[userInfo setObject:commit forKey:@"sha"];

	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexFinishedCommit
														object:self
													  userInfo:userInfo];
	if (!success)
		return;

	self.repository.hasChanged = YES;

	self.amendEnvironment = nil;
	if (self.amend)
		self.amend = NO;
	else
		[self refresh];
}

- (void)postCommitUpdate:(NSString *)update
{
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitIndexCommitStatus
														object:self
													  userInfo:[NSDictionary dictionaryWithObject:update forKey:@"description"]];
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
	NSArray<NSString *> *paths = [files valueForKey:@"path"];
	NSError *error = nil;
	BOOL success = stage ? [self.mutationService stagePaths:paths error:&error] : [self.mutationService unstagePaths:paths parentTree:self.parentTree error:&error];
	if (!success) {
		[self postOperationFailed:[NSString stringWithFormat:@"Error in %@ files. Return value: %@", (stage ? @"staging" : @"unstaging"), error.userInfo[PBTaskTerminationStatusKey]]];
		return NO;
	}
	for (PBChangedFile *file in files) {
		file.hasStagedChanges = stage;
		file.hasUnstagedChanges = !stage;
	}

	[self postIndexUpdated];

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
	NSArray<NSString *> *paths = [discardFiles valueForKey:@"path"];
	NSError *error = nil;
	if (![self.mutationService discardPaths:paths error:&error]) {
		[self postOperationFailed:[NSString stringWithFormat:@"Discarding changes failed with return value %@", error.userInfo[PBTaskTerminationStatusKey]]];
		return;
	}

	for (PBChangedFile *file in discardFiles)
		if (file.status != NEW)
			file.hasUnstagedChanges = NO;

	[self postIndexUpdated];
}

- (BOOL)applyPatch:(NSString *)hunk stage:(BOOL)stage reverse:(BOOL)reverse;
{
	NSError *error = nil;
	if (![self.mutationService applyPatch:hunk stage:stage reverse:reverse error:&error]) {
		NSString *message = [NSString stringWithFormat:@"Applying patch failed with return value %@. Error: %@", error.userInfo[PBTaskTerminationStatusKey], error.userInfo[PBTaskTerminationOutputKey]];
		[self postOperationFailed:message];
		return NO;
	}

	// TODO: Try to be smarter about what to refresh
	[self refresh];
	return YES;
}


- (nullable NSString *)diffForFile:(PBChangedFile *)file staged:(BOOL)staged contextLines:(NSUInteger)context
{
	NSError *error = nil;
	NSString *output = [self.mutationService diffForPath:file.path
												  status:file.status
										hasStagedChanges:file.hasStagedChanges
												  staged:staged
											  parentTree:self.parentTree
											contextLines:context
												   error:&error];
	if (!output)
		PBLogError(error);
	return output;
}

@end

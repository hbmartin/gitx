//
//  PBGitCommitController.m
//  GitX
//
//  Created by Pieter de Bie on 19-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBGitCommitController.h"
#import "GitX-Swift.h"
#import "NSFileHandleExt.h"
#import "PBChangedFile.h"
#import "PBWebChangesController.h"
#import "PBGitIndex.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"
#import "PBGitRepositoryWatcher.h"
#import "PBCommitMessageView.h"
#import "PBTask.h"
#import "NSSplitView+GitX.h"

#import <ObjectiveGit/GTRepository.h>
#import <ObjectiveGit/GTConfiguration.h>

#define kMinimalCommitMessageLength 3
#define kNotificationDictionaryDescriptionKey @"description"
#define kNotificationDictionaryMessageKey @"message"

@interface PBGitCommitController () <NSTextViewDelegate, NSMenuDelegate> {
	IBOutlet PBCommitMessageView *commitMessageView;

	IBOutlet NSArrayController *unstagedFilesController;
	IBOutlet NSArrayController *stagedFilesController;
	IBOutlet NSArrayController *trackedFilesController;

	IBOutlet NSTabView *controlsTabView;
	IBOutlet NSButton *commitButton;
	IBOutlet NSButton *pushAfterCommitButton;
	IBOutlet NSPopUpButton *pushRemotePopUpButton;

	IBOutlet PBWebChangesController *webController;
	IBOutlet NSSplitView *commitSplitView;
}

@property (weak) IBOutlet NSTableView *unstagedTable;
@property (weak) IBOutlet NSTableView *stagedTable;
@property (nonatomic, strong) PBCommitWorkflowState *commitWorkflowState;
@property (nonatomic, strong) PBCommitTableInteractionCoordinator *tableInteractionCoordinator;
@property (nonatomic, strong) PBRepositoryUISettings *repositoryUISettings;
@property (nonatomic, strong, nullable) PBCommitProgressSheetController *commitProgressSheet;
@property (nonatomic) BOOL pushCapabilityAvailable;

- (nullable NSString *)selectedPushRemoteName;
- (void)reloadPushRemotes;
- (void)finishCommitProgressSheet;

@end

@implementation PBGitCommitController

@synthesize stagedTable = stagedTable;
@synthesize unstagedTable = unstagedTable;

- (id)initWithRepository:(PBGitRepository *)theRepository superController:(PBGitWindowController *)controller
{
	if (!(self = [super initWithRepository:theRepository superController:controller]))
		return nil;

	PBGitIndex *index = theRepository.index;
	_commitWorkflowState = [[PBCommitWorkflowState alloc] init];
	_repositoryUISettings = [[PBRepositoryUISettings alloc] initWithRepository:theRepository];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshFinished:) name:PBGitIndexFinishedIndexRefresh object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(commitStatusUpdated:) name:PBGitIndexCommitStatus object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(commitOutputReceived:) name:PBGitIndexCommitOutput object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(commitFinished:) name:PBGitIndexFinishedCommit object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(commitFailed:) name:PBGitIndexCommitFailed object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(commitHookFailed:) name:PBGitIndexCommitHookFailed object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(amendCommit:) name:PBGitIndexAmendMessageAvailable object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(indexChanged:) name:PBGitIndexIndexUpdated object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(indexOperationFailed:) name:PBGitIndexOperationFailed object:index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(repositoryUpdatedNotification:) name:PBGitRepositoryEventNotification object:theRepository];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:nil];

	return self;
}

- (void)awakeFromNib
{
	/* FIXME: Be careful with this method: since PBGitCommitController is refrerenced from multiple NIBS
	 * and therefore this method is called *really* often. Be sure not to register for listener here as this results
	 * into multi receptions of notifications! Use method `initWithRepository` instead for register notitifications.
	 */

	[commitSplitView pb_restoreAutosavedPositions];

	[super awakeFromNib];
	[PBCommitLayoutCoordinator configureOuterSplitView:commitSplitView
									 commitMessageView:commitMessageView
										 unstagedTable:unstagedTable
										   stagedTable:stagedTable];

	commitMessageView.repository = self.repository;
	commitMessageView.delegate = self;
	commitMessageView.accessibilityIdentifier = @"CommitMessage";

	NSMutableDictionary *attrs = commitMessageView.typingAttributes.mutableCopy;
	if (!attrs) {
		attrs = [NSMutableDictionary dictionary];
	}
	attrs[NSFontAttributeName] = [NSFont preferredFontForTextStyle:NSFontTextStyleBody options:@{}];
	commitMessageView.typingAttributes = attrs;

	[unstagedFilesController setFilterPredicate:[NSPredicate predicateWithFormat:@"hasUnstagedChanges == 1"]];
	[stagedFilesController setFilterPredicate:[NSPredicate predicateWithFormat:@"hasStagedChanges == 1"]];
	[trackedFilesController setFilterPredicate:[NSPredicate predicateWithFormat:@"status > 0"]];

	[unstagedFilesController setSortDescriptors:[NSArray arrayWithObjects:
															 [[NSSortDescriptor alloc] initWithKey:@"status"
																						 ascending:false],
															 [[NSSortDescriptor alloc] initWithKey:@"path"
																						 ascending:true],
															 nil]];
	[stagedFilesController setSortDescriptors:[NSArray arrayWithObject:
														   [[NSSortDescriptor alloc] initWithKey:@"path"
																					   ascending:true]]];

	[stagedFilesController setAutomaticallyRearrangesObjects:NO];
	[unstagedFilesController setAutomaticallyRearrangesObjects:NO];

	[unstagedTable setDoubleAction:@selector(didDoubleClickOnTable:)];
	[stagedTable setDoubleAction:@selector(didDoubleClickOnTable:)];

	[unstagedTable setTarget:self];
	[stagedTable setTarget:self];
	unstagedTable.accessibilityIdentifier = @"UnstagedFiles";
	stagedTable.accessibilityIdentifier = @"StagedFiles";
	pushAfterCommitButton.accessibilityIdentifier = @"PushAfterCommit";
	pushRemotePopUpButton.accessibilityIdentifier = @"PushRemote";
	pushAfterCommitButton.state = self.repositoryUISettings.pushAfterCommit ? NSControlStateValueOn : NSControlStateValueOff;

	self.tableInteractionCoordinator = [[PBCommitTableInteractionCoordinator alloc] initWithRepository:self.repository
																								 index:self.index
																			   unstagedFilesController:unstagedFilesController
																				 stagedFilesController:stagedFilesController
																						 unstagedTable:unstagedTable
																						   stagedTable:stagedTable];

	// Copy the menu over so we have two discrete menu objects
	// which allows us to tell them apart in our delegate methods
	stagedTable.menu = [unstagedTable.menu copy];

	[self reloadPushRemotes];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	BOOL shouldRefresh = [PBRepositoryRefreshPolicy shouldRefreshStatCacheAfterApplicationActivation];
	NSLog(@"[GitX] Application activation %@ the index stat-cache refresh", shouldRefresh ? @"triggered" : @"skipped");
	if (shouldRefresh) {
		[self.repository.index refreshStatCache];
	}
	[self reloadPushRemotes];
}

- (void)repositoryUpdatedNotification:(NSNotification *)notification
{
	PBGitRepositoryWatcherEventType eventType = [(NSNumber *)[[notification userInfo] objectForKey:kPBGitRepositoryEventTypeUserInfoKey] unsignedIntValue];
	if (eventType & (PBGitRepositoryWatcherEventTypeWorkingDirectory | PBGitRepositoryWatcherEventTypeIndex)) {
		// refresh if the working directory or index is modified
		[self refresh:self];
	}
	if (eventType & PBGitRepositoryWatcherEventTypeGitDirectory) {
		[self.repository reloadRefs];
		[self reloadPushRemotes];
	}
}

- (void)updateView
{
	[self refresh:nil];
	[self reloadPushRemotes];
}

- (void)closeView
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[webController closeView];
	[super closeView];
}

- (NSResponder *)firstResponder;
{
	return commitMessageView;
}

- (PBGitIndex *)index
{
	return self.repository.index;
}

- (NSString *)selectedPushRemoteName
{
	id representedObject = pushRemotePopUpButton.selectedItem.representedObject;
	return [representedObject isKindOfClass:NSString.class] ? representedObject : nil;
}

- (void)reloadPushRemotes
{
	BOOL wasAvailable = self.pushCapabilityAvailable;
	BOOL livePushChoice = pushAfterCommitButton.state == NSControlStateValueOn;
	NSString *previousSelection = [self selectedPushRemoteName];
	NSArray<NSString *> *remotes = [PBCommitRemotePresentationPolicy sortedRemoteNames:self.repository.remotes];
	PBGitRef *headRef = self.repository.headRef.ref;
	NSString *trackingRemoteName = nil;
	if ([PBCommitRemotePresentationPolicy shouldResolveTrackingRemoteForRemoteNames:remotes
																  previousSelection:previousSelection
																		   isBranch:headRef.isBranch]) {
		trackingRemoteName = [self.repository remoteRefForBranch:headRef error:NULL].remoteName;
	}
	PBCommitRemotePresentation *presentation = [PBCommitRemotePresentationPolicy presentationForRemoteNames:remotes
																						  previousSelection:previousSelection
																						 trackingRemoteName:trackingRemoteName
																								   isBranch:headRef.isBranch];

	[pushRemotePopUpButton removeAllItems];
	if (presentation.remoteNames.count == 0) {
		[pushRemotePopUpButton addItemWithTitle:NSLocalizedString(@"No Remotes", @"Placeholder in the commit push remote popup when no remotes are configured")];
		pushRemotePopUpButton.lastItem.enabled = NO;
	} else {
		for (NSString *remoteName in presentation.remoteNames) {
			[pushRemotePopUpButton addItemWithTitle:remoteName];
			pushRemotePopUpButton.lastItem.representedObject = remoteName;
		}
		[pushRemotePopUpButton selectItemWithTitle:presentation.selectedRemoteName];
	}

	pushAfterCommitButton.enabled = presentation.canPush;
	pushRemotePopUpButton.enabled = presentation.canPush;
	if (presentation.canPush) {
		BOOL restoredChoice = wasAvailable ? livePushChoice : self.repositoryUISettings.pushAfterCommit;
		pushAfterCommitButton.state = restoredChoice ? NSControlStateValueOn : NSControlStateValueOff;
	} else {
		pushAfterCommitButton.state = NSControlStateValueOff;
	}
	self.pushCapabilityAvailable = presentation.canPush;
	NSLog(@"[GitX] Reloaded commit push controls (remote count: %lu, can push: %@)",
		  presentation.remoteNames.count,
		  presentation.canPush ? @"yes" : @"no");
}

- (void)commitWithVerification:(BOOL)doVerify
{
	BOOL mergeInProgress = [[NSFileManager defaultManager] fileExistsAtPath:[self.repository.gitURL.path stringByAppendingPathComponent:@"MERGE_HEAD"]];
	NSInteger stagedCount = [[stagedFilesController arrangedObjects] count];
	NSError *transformationError = nil;
	NSString *commitMessage = [PBCommitMessageEditCoordinator transformMessage:commitMessageView.string
																	inTextView:commitMessageView
																	repository:self.repository
																		 error:&transformationError];
	if (!commitMessage) {
		[self.windowController showErrorSheet:transformationError];
		return;
	}
	PBCommitSubmissionPlan *validationPlan = [PBCommitSubmissionPolicy planForMergeInProgress:mergeInProgress
																				  stagedCount:stagedCount
																				messageLength:commitMessage.length
																				  pushEnabled:NO
																				pushRequested:NO
																					 isBranch:NO
																				   remoteName:nil];

	if (validationPlan.disposition == PBCommitSubmissionDispositionMergeInProgress) {
		NSString *message = NSLocalizedString(@"Cannot commit merges",
											  @"Title for sheet that GitX cannot create merge commits");
		NSString *info = NSLocalizedString(@"GitX cannot commit merges yet. Please commit your changes from the command line.",
										   @"Information text for sheet that GitX cannot create merge commits");

		[self.windowController showMessageSheet:message infoText:info];
		return;
	}

	if (validationPlan.disposition == PBCommitSubmissionDispositionNoStagedChanges) {
		NSString *message = NSLocalizedString(@"No changes to commit",
											  @"Title for sheet that you need to stage changes before creating a commit");
		NSString *info = NSLocalizedString(@"You need to stage some changed files before committing by moving them to the list of Staged Changes.",
										   @"Information text for sheet that you need to stage changes before creating a commit");

		[self.windowController showMessageSheet:message infoText:info];
		return;
	}

	if (validationPlan.disposition == PBCommitSubmissionDispositionMessageTooShort) {
		NSString *message = NSLocalizedString(@"Missing commit message",
											  @"Title for sheet that you need to enter a commit message before creating a commit");
		NSString *info = [NSString stringWithFormat:
									   NSLocalizedString(@"Please enter a commit message at least %i characters long before commiting.",
														 @"Format for sheet that you need to enter a commit message before creating a commit giving the minimum length of the commit message required"),
									   kMinimalCommitMessageLength];
		[self.windowController showMessageSheet:message infoText:info];
		return;
	}

	[self.commitWorkflowState clear];
	PBGitRef *headRef = self.repository.headRef.ref;
	NSString *remoteName = [self selectedPushRemoteName];
	PBCommitSubmissionPlan *submissionPlan = [PBCommitSubmissionPolicy planForMergeInProgress:NO
																				  stagedCount:stagedCount
																				messageLength:commitMessage.length
																				  pushEnabled:pushAfterCommitButton.enabled
																				pushRequested:pushAfterCommitButton.state == NSControlStateValueOn
																					 isBranch:headRef.isBranch
																				   remoteName:remoteName];
	if (submissionPlan.shouldArmPendingPush) {
		[self.commitWorkflowState armWithBranchRef:headRef remoteName:remoteName];
	}
	[self.commitWorkflowState beginSubmissionWithPushChoice:pushAfterCommitButton.state == NSControlStateValueOn
												canRemember:pushAfterCommitButton.enabled];

	[stagedFilesController setSelectionIndexes:[NSIndexSet indexSet]];
	[unstagedFilesController setSelectionIndexes:[NSIndexSet indexSet]];

	self.isBusy = YES;
	commitMessageView.editable = NO;

	self.commitProgressSheet = [[PBCommitProgressSheetController alloc] initWithRepositoryWindowController:self.windowController];
	[self.commitProgressSheet beginWithPhase:NSLocalizedString(@"Preparing commit…", @"Initial interactive commit progress phase")];
	[self.repository.index commitWithMessage:commitMessage andVerify:doVerify];
}

- (void)discardChangesForFiles:(NSArray *)files force:(BOOL)force
{
	void (^performDiscard)(void) = ^{
		[self.repository.index discardChangesForFiles:files];
	};

	if (!force) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = NSLocalizedString(@"Discard changes", @"Title for Discard Changes sheet");
		alert.informativeText = NSLocalizedString(@"Are you sure you wish to discard the changes to this file?\n\nYou cannot undo this operation.", @"Informative text for Discard Changes sheet");

		[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button in Discard Changes sheet")];
		[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button in Discard Changes sheet")];


		[self.windowController confirmDialog:alert suppressionIdentifier:nil forAction:performDiscard];
	} else {
		performDiscard();
	}
}

#pragma mark IBActions

- (IBAction)signOff:(id)sender
{
	NSError *error = nil;
	GTConfiguration *config = [self.repository.gtRepo configurationWithError:&error];
	NSString *userName = [config stringForKey:@"user.name"];
	NSString *userEmail = [config stringForKey:@"user.email"];
	if (!(userName && userEmail)) {
		return [self.windowController showMessageSheet:NSLocalizedString(@"User‘s name not set",
																		 @"Title for sheet that the user’s name is not set in the git configuration")
											  infoText:NSLocalizedString(@"Signing off a commit requires setting user.name and user.email in your git config",
																		 @"Information text for sheet that the user’s name is not set in the git configuration")];
	}

	PBCommitMessageResult *result = [PBCommitMessagePolicy messageByAddingSignOffToMessage:commitMessageView.string
																				  userName:userName
																				 userEmail:userEmail];
	if (result.didAddSignOff) {
		NSArray *selectedRanges = [commitMessageView selectedRanges];
		commitMessageView.string = result.message;
		[commitMessageView setSelectedRanges:selectedRanges];
	}
}

- (IBAction)refresh:(id)sender
{
	self.isBusy = YES;
	self.status = NSLocalizedString(@"Refreshing index…", @"Message in status bar while the index is refreshing");
	[self.repository.index refresh];

	// Reload refs (in case HEAD changed)
	[self.repository reloadRefs];
}

- (IBAction)prepareCommitMessage:(id)sender
{
	self.isBusy = YES;

	NSString *prepareCommitMessage = [[[self repository] index] createPrepareCommitMessage];

	if (prepareCommitMessage != nil) {
		NSRange replacementRange = NSMakeRange(0, [[commitMessageView string] length]);

		if ([commitMessageView shouldChangeTextInRange:replacementRange replacementString:prepareCommitMessage]) {
			[commitMessageView replaceCharactersInRange:replacementRange withString:prepareCommitMessage];
		}
	}

	self.isBusy = NO;
}

- (IBAction)commit:(id)sender
{
	[self commitWithVerification:YES];
}

- (IBAction)forceCommit:(id)sender
{
	[self commitWithVerification:NO];
}

- (IBAction)toggleAmendCommit:(id)sender
{
	[[[self repository] index] setAmend:![[[self repository] index] isAmend]];
}

- (NSArray<PBChangedFile *> *)selectedFilesForSender:(id)sender
{
	NSParameterAssert(sender != nil);

	if (![sender isKindOfClass:[NSMenuItem class]]) return nil;

	NSMenuItem *menuItem = (NSMenuItem *)sender;
	NSTableView *table = (menuItem.menu == stagedTable.menu ? stagedTable : unstagedTable);
	NSArrayController *controller = (table.tag == 0 ? unstagedFilesController : stagedFilesController);
	return controller.selectedObjects;
}

- (IBAction)openFiles:(id)sender
{
	NSArray<PBChangedFile *> *selectedFiles = [self selectedFilesForSender:sender];

	NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
	NSURL *workingDirectoryURL = self.repository.workingDirectoryURL;
	for (PBChangedFile *file in selectedFiles) {
		[fileURLs addObject:[workingDirectoryURL URLByAppendingPathComponent:file.path]];
	}
	[self.windowController openURLs:fileURLs];
}

- (IBAction)revealInFinder:(id)sender
{
	NSArray<PBChangedFile *> *selectedFiles = [self selectedFilesForSender:sender];

	NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
	NSURL *workingDirectoryURL = self.repository.workingDirectoryURL;
	for (PBChangedFile *file in selectedFiles) {
		[fileURLs addObject:[workingDirectoryURL URLByAppendingPathComponent:file.path]];
	}
	[self.windowController revealURLsInFinder:fileURLs];
}

- (IBAction)moveToTrash:(id)sender
{
	NSArray<PBChangedFile *> *selectedFiles = [self selectedFilesForSender:sender];

	NSURL *workingDirectoryURL = self.repository.workingDirectoryURL;

	NSAlert *confirmTrash = [[NSAlert alloc] init];
	confirmTrash.alertStyle = NSAlertStyleWarning;
	confirmTrash.messageText = NSLocalizedString(@"Move to trash", @"Move to trash alert - title");
	confirmTrash.informativeText = NSLocalizedString(@"Do you want to move the following files to the trash ?", @"Move to trash alert - message");
	[confirmTrash addButtonWithTitle:NSLocalizedString(@"OK", @"Move to trash alert - OK button")];
	[confirmTrash addButtonWithTitle:NSLocalizedString(@"Cancel", @"Move to trash alert - Cancel button")];

	[self.windowController confirmDialog:confirmTrash
				   suppressionIdentifier:nil
							   forAction:^{
								   BOOL anyTrashed = NO;
								   for (PBChangedFile *file in selectedFiles) {
									   NSURL *fileURL = [workingDirectoryURL URLByAppendingPathComponent:[file path]];

									   NSError *error = nil;
									   NSURL *resultURL = nil;
									   if ([[NSFileManager defaultManager] trashItemAtURL:fileURL
																		 resultingItemURL:&resultURL
																					error:&error]) {
										   anyTrashed = YES;
									   }
								   }
								   if (anyTrashed) {
									   [self.repository.index refresh];
								   }
							   }];
}

- (IBAction)ignoreFiles:(id)sender
{
	NSArray<PBChangedFile *> *selectedFiles = [self selectedFilesForSender:sender];
	if ([selectedFiles count] == 0)
		return;

	// Build selected files
	NSMutableArray *fileList = [NSMutableArray array];
	for (PBChangedFile *file in selectedFiles) {
		NSString *name = file.path;
		if ([name length] > 0)
			[fileList addObject:name];
	}

	NSError *error = nil;
	BOOL success = [self.repository ignoreFilePaths:fileList error:&error];
	if (!success) {
		[self.windowController showErrorSheet:error];
	}
	[self.repository.index refresh];
}

- (IBAction)stageFiles:(id)sender
{
	[self.tableInteractionCoordinator stageSelectedFiles];
}

- (IBAction)unstageFiles:(id)sender
{
	[self.tableInteractionCoordinator unstageSelectedFiles];
}

- (void)fileChangesTableViewDidRequestStagingToggle:(PBFileChangesTableView *)tableView
{
	[self.tableInteractionCoordinator toggleStagingForTableView:tableView];
}

- (IBAction)discardFiles:(id)sender
{
	NSArray *selectedFiles = unstagedFilesController.selectedObjects;
	if ([selectedFiles count] > 0)
		[self discardChangesForFiles:selectedFiles force:FALSE];
}

- (IBAction)discardFilesForcibly:(id)sender
{
	NSArray *selectedFiles = unstagedFilesController.selectedObjects;
	if ([selectedFiles count] > 0)
		[self discardChangesForFiles:selectedFiles force:TRUE];
}

#pragma mark PBGitIndex Notification handling

- (void)refreshFinished:(NSNotification *)notification
{
	self.isBusy = NO;
	self.status = NSLocalizedString(@"Index refresh finished", @"Message in status bar when refreshing the index is done");
}

- (void)commitStatusUpdated:(NSNotification *)notification
{
	self.status = notification.userInfo[kNotificationDictionaryDescriptionKey];
	[self.commitProgressSheet updatePhase:self.status];
}

- (void)commitOutputReceived:(NSNotification *)notification
{
	NSString *output = notification.userInfo[@"output"];
	if (output.length > 0)
		[self.commitProgressSheet appendOutput:output];
}

- (void)commitFinished:(NSNotification *)notification
{
	[self finishCommitProgressSheet];
	commitMessageView.editable = YES;
	commitMessageView.string = @"";
	[webController setStateMessage:notification.userInfo[kNotificationDictionaryDescriptionKey]];

	NSNumber *rememberedPushChoice = self.commitWorkflowState.pendingRememberedPushChoice;
	PBCommitPushPlan *pushPlan = [self.commitWorkflowState consumePendingPush];
	if (rememberedPushChoice) {
		self.repositoryUISettings.pushAfterCommit = rememberedPushChoice.boolValue;
		pushAfterCommitButton.state = rememberedPushChoice.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
		NSLog(@"[GitX] Remembered repository Push-after-commit choice: %@",
			  rememberedPushChoice.boolValue ? @"on" : @"off");
	}

	if (pushPlan.branchRef.isBranch && pushPlan.remoteName.length > 0) {
		PBGitRef *remoteRef = [PBGitRef refFromString:[kGitXRemoteRefPrefix stringByAppendingString:pushPlan.remoteName]];
		[self.windowController performPushForBranch:pushPlan.branchRef toRemote:remoteRef requiresConfirmation:NO];
	}
}

- (void)commitFailed:(NSNotification *)notification
{
	[self finishCommitProgressSheet];
	self.isBusy = NO;
	commitMessageView.editable = YES;
	[self.commitWorkflowState clear];

	NSString *reason = notification.userInfo[kNotificationDictionaryDescriptionKey];
	self.status = [NSString stringWithFormat:
								NSLocalizedString(@"Commit failed: %@",
												  @"Message in status bar when creating a commit has failed, including the reason for the failure"),
								reason];
	[self.windowController showMessageSheet:NSLocalizedString(@"Commit failed", @"Title for sheet that creating a commit has failed")
								   infoText:reason];
}

- (void)commitHookFailed:(NSNotification *)notification
{
	[self finishCommitProgressSheet];
	self.isBusy = NO;
	commitMessageView.editable = YES;
	[self.commitWorkflowState clear];

	NSString *reason = notification.userInfo[kNotificationDictionaryDescriptionKey];
	self.status = [NSString stringWithFormat:
								NSLocalizedString(@"Commit hook failed: %@",
												  @"Message in status bar when running a commit hook failed, including the reason for the failure"),
								reason];
	[self.windowController showCommitHookFailedSheet:NSLocalizedString(@"Commit hook failed", @"Title for sheet that running a commit hook has failed")
											infoText:reason
									commitController:self];
}

- (void)finishCommitProgressSheet
{
	[self.commitProgressSheet finish];
	self.commitProgressSheet = nil;
}

- (void)amendCommit:(NSNotification *)notification
{
	if (![PBCommitMessagePolicy shouldReplaceMessageForAmendWithCurrentMessage:[commitMessageView string]]) {
		return;
	}

	NSString *message = notification.userInfo[kNotificationDictionaryMessageKey];
	commitMessageView.string = message;
}

- (void)indexChanged:(NSNotification *)notification
{
	[stagedFilesController rearrangeObjects];
	[unstagedFilesController rearrangeObjects];

	commitButton.enabled = ([[stagedFilesController arrangedObjects] count] > 0);
}

- (void)indexOperationFailed:(NSNotification *)notification
{
	[self.windowController showMessageSheet:NSLocalizedString(@"Index operation failed", @"Title for sheet that running an index operation has failed")
								   infoText:notification.userInfo[kNotificationDictionaryDescriptionKey]];
}

#pragma mark NSTextView delegate methods

- (void)focusTable:(NSTableView *)table
{
	[self.tableInteractionCoordinator focusTable:table];
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector;
{
	return [self.tableInteractionCoordinator handleCommandSelector:commandSelector];
}

#pragma mark NSMenu delegate

static NSArray<PBCommitMenuFile *> *PBCommitMenuFiles(NSArray<PBChangedFile *> *files)
{
	NSMutableArray<PBCommitMenuFile *> *snapshots = [NSMutableArray arrayWithCapacity:files.count];
	for (PBChangedFile *file in files) {
		[snapshots addObject:[[PBCommitMenuFile alloc] initWithPath:file.path
															 status:file.status
												 hasUnstagedChanges:file.hasUnstagedChanges]];
	}
	return snapshots;
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
	for (NSMenuItem *item in menu.itemArray) {
		[self validateMenuItem:item];
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	NSTableView *table = (menuItem.menu == stagedTable.menu ? stagedTable : unstagedTable);
	NSArray<PBChangedFile *> *filesForStaging = unstagedFilesController.selectedObjects;
	NSArray<PBChangedFile *> *filesForUnstaging = stagedFilesController.selectedObjects;
	NSArray<PBChangedFile *> *selectedFiles = (table.tag == 0 ? filesForStaging : filesForUnstaging);
	BOOL isInContextualMenu = (menuItem.parentItem == nil);
	BOOL singleSelectionIsSubmodule = isInContextualMenu && menuItem.action == @selector(openFiles:) && selectedFiles.count == 1 &&
		[self.repository submoduleAtPath:selectedFiles.firstObject.path
								   error:NULL] != nil;
	BOOL isAmend = menuItem.action == @selector(toggleAmendCommit:) && self.repository.index.isAmend;
	BOOL prepareHookExists = menuItem.action == @selector(prepareCommitMessage:) &&
		[self.repository hookExists:@"prepare-commit-msg"];
	PBCommitMenuPresentation *presentation = [PBCommitMenuPresenter presentationForAction:menuItem.action
																			unstagedFiles:PBCommitMenuFiles(filesForStaging)
																			  stagedFiles:PBCommitMenuFiles(filesForUnstaging)
																		  isStagedContext:table.tag != 0
																			  allowsTrash:table.tag != 1
																		 isContextualMenu:isInContextualMenu
															   singleSelectionIsSubmodule:singleSelectionIsSubmodule
																				  isAmend:isAmend
																		prepareHookExists:prepareHookExists
																		  fallbackEnabled:menuItem.enabled];
	if (presentation.title != nil) {
		menuItem.title = presentation.title;
	}
	if (presentation.updatesHidden) {
		menuItem.hidden = presentation.hidden;
	}
	if (presentation.updatesAlternate) {
		menuItem.alternate = presentation.alternate;
	}
	if (presentation.updatesState) {
		menuItem.state = presentation.state;
	}
	return presentation.enabled;
}

#pragma mark PBFileChangedTableView delegate

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	[self.tableInteractionCoordinator displayCell:cell forTableColumn:tableColumn row:rowIndex inTableView:tableView];
}

- (void)didDoubleClickOnTable:(NSTableView *)tableView
{
	[self.tableInteractionCoordinator didDoubleClickTableView:tableView];
}

- (BOOL)tableView:(NSTableView *)tv writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
	return [self.tableInteractionCoordinator writeRowsWithIndexes:rowIndexes fromTableView:tv toPasteboard:pboard];
}

- (NSDragOperation)tableView:(NSTableView *)tableView
				validateDrop:(id<NSDraggingInfo>)info
				 proposedRow:(NSInteger)row
	   proposedDropOperation:(NSTableViewDropOperation)operation
{
	return [self.tableInteractionCoordinator validateDrop:info inTableView:tableView];
}

- (BOOL)tableView:(NSTableView *)aTableView
	   acceptDrop:(id<NSDraggingInfo>)info
			  row:(NSInteger)row
	dropOperation:(NSTableViewDropOperation)operation
{
	return [self.tableInteractionCoordinator acceptDrop:info inTableView:aTableView];
}

@end

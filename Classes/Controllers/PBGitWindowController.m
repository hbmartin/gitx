//
//  PBGitWindowController.m
//  GitX
//

#import "PBGitWindowController.h"

#import "GitX-Swift.h"
#import "PBSourceViewItem.h"
#import "PBViewController.h"
#import "PBGitBinary.h"
#import "PBGitCommit.h"
#import "PBGitCommitController.h"
#import "PBGitDefaults.h"
#import "PBGitHistoryController.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitSidebarController.h"

@interface PBGitWindowController () {
	__weak PBViewController *contentController;
	PBGitSidebarController *_sidebarController;
	PBGitHistoryController *_historyViewController;
	PBGitCommitController *_commitViewController;
	PBRepositoryFocusRefreshCoordinator *_focusRefreshCoordinator;
	PBRepositoryActionContextResolver *_actionContextResolver;
	PBRepositoryRemoteActionCoordinator *_remoteActionCoordinator;
	PBRepositoryReferenceActionCoordinator *_referenceActionCoordinator;
	PBRepositoryStashActionCoordinator *_stashActionCoordinator;
	PBWorkspaceActionCoordinator *_workspaceActionCoordinator;
	PBRepositoryToolbarController *_repositoryToolbarController;
	NSMapTable<PBViewController *, NSResponder *> *_contentFirstResponders;

	__weak IBOutlet NSView *sourceListControlsView;
	__weak IBOutlet NSSplitView *splitView;
	__weak IBOutlet NSView *sourceSplitView;
	__weak IBOutlet NSView *contentSplitView;
	__weak IBOutlet NSTextField *statusField;
	__weak IBOutlet NSProgressIndicator *progressIndicator;
	__weak IBOutlet NSButton *jumpToCheckedOutBranchButton;
}
@end

#pragma clang diagnostic push
// Public dialog methods are implemented in PBGitWindowController+Dialogs.m.
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation PBGitWindowController

@dynamic document;

- (instancetype)init
{
	return [super initWithWindowNibName:@"RepositoryWindow"];
}

- (PBGitRepository *)repository
{
	return self.document.repository;
}

- (void)ensureActionCoordinators
{
	if (!self.repository) return;
	if (!_actionContextResolver) _actionContextResolver = [[PBRepositoryActionContextResolver alloc] init];
	if (!_remoteActionCoordinator) _remoteActionCoordinator = [[PBRepositoryRemoteActionCoordinator alloc] initWithRepository:self.repository windowController:self];
	if (!_referenceActionCoordinator) _referenceActionCoordinator = [[PBRepositoryReferenceActionCoordinator alloc] initWithRepository:self.repository windowController:self];
	if (!_stashActionCoordinator) _stashActionCoordinator = [[PBRepositoryStashActionCoordinator alloc] initWithRepository:self.repository windowController:self];
	if (!_workspaceActionCoordinator) _workspaceActionCoordinator = [[PBWorkspaceActionCoordinator alloc] initWithRepository:self.repository];
}

- (void)ensureFocusRefreshCoordinator
{
	if (_focusRefreshCoordinator || !self.repository) return;
	__weak typeof(self) weakSelf = self;
	_focusRefreshCoordinator = [[PBRepositoryFocusRefreshCoordinator alloc]
		initWithRepository:self.repository
		 gitExecutablePath:PBGitBinary.path
			refreshHandler:^{
				[weakSelf refresh:weakSelf];
			}];
}

- (void)synchronizeWindowTitleWithDocumentName
{
	[super synchronizeWindowTitleWithDocumentName];
	if (self.isWindowLoaded) self.window.representedURL = self.repository.workingDirectoryURL;
}

- (void)windowWillClose:(NSNotification *)notification
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_focusRefreshCoordinator cancel];
	[self.sidebarViewController closeView];
	[self.historyViewController closeView];
	[self.commitViewController closeView];
	_sidebarController = nil;
	_historyViewController = nil;
	_commitViewController = nil;
	_repositoryToolbarController = nil;
	[[PBWelcomeWindowController shared] showIfNeededAfterDelay];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(revealInFinder:) || menuItem.action == @selector(openInTerminal:)) {
		[self ensureActionCoordinators];
		return _workspaceActionCoordinator.hasWorkingDirectory;
	}
	if (menuItem.action == @selector(showCommitView:)) {
		menuItem.state = contentController == _commitViewController;
		return !self.repository.isBareRepository;
	}
	if (menuItem.action == @selector(showHistoryView:)) {
		menuItem.state = contentController != _commitViewController;
		return !self.repository.isBareRepository;
	}
	if (menuItem.action == @selector(fetchRemote:))
		return [self validateMenuItem:menuItem remoteTitle:@"Fetch “%@”" plainTitle:@"Fetch"];
	if (menuItem.action == @selector(showRepositorySettings:)) return self.repository != nil;
	if (menuItem.action == @selector(pullRemote:))
		return [self validateMenuItem:menuItem remoteTitle:@"Pull From “%@”" plainTitle:@"Pull"];
	if (menuItem.action == @selector(pullRebaseRemote:))
		return [self validateMenuItem:menuItem remoteTitle:@"Pull From “%@” and Rebase" plainTitle:@"Pull and Rebase"];
	return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem remoteTitle:(NSString *)remoteTitle plainTitle:(NSString *)plainTitle
{
	PBGitRef *ref = self.selectedRef;
	if (!ref) return NO;
	PBGitRef *remoteRef = [self.repository remoteRefForBranch:ref error:NULL];
	if (ref.isRemote || remoteRef) {
		menuItem.title = [NSString stringWithFormat:NSLocalizedString(remoteTitle, @""), (remoteRef ?: ref).remoteName];
		menuItem.representedObject = ref;
		return YES;
	}
	menuItem.title = NSLocalizedString(plainTitle, @"");
	return NO;
}

- (void)windowDidLoad
{
	[super windowDidLoad];
	[self ensureActionCoordinators];
	[self ensureFocusRefreshCoordinator];
	[self.window setFrameUsingName:@"GitX"];
	self.window.representedURL = self.repository.workingDirectoryURL;
	_sidebarController = [[PBGitSidebarController alloc] initWithRepository:self.repository superController:self];
	_historyViewController = [[PBGitHistoryController alloc] initWithRepository:self.repository superController:self];
	_commitViewController = [[PBGitCommitController alloc] initWithRepository:self.repository superController:self];
	_repositoryToolbarController = [[PBRepositoryToolbarController alloc] initWithWindowController:self];
	_contentFirstResponders = [NSMapTable strongToWeakObjectsMapTable];
	[_repositoryToolbarController install];
	_sidebarController.view.frame = sourceSplitView.bounds;
	[sourceSplitView addSubview:_sidebarController.view];
	[sourceListControlsView addSubview:_sidebarController.sourceListControlsView];
	[statusField.cell setBackgroundStyle:NSBackgroundStyleRaised];
	progressIndicator.usesThreadedAnimation = YES;
	jumpToCheckedOutBranchButton.accessibilityIdentifier = @"JumpToCheckedOutBranchButton";
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshPreferenceDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];
	[self refreshPreferenceDidChange:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	[self ensureFocusRefreshCoordinator];
	[_focusRefreshCoordinator applicationDidBecomeActive];
}

- (void)refreshPreferenceDidChange:(NSNotification *)notification
{
	[self ensureFocusRefreshCoordinator];
	[_focusRefreshCoordinator updatePreferenceEnabled:[PBRepositoryRefreshPolicy shouldRefreshAfterApplicationActivation]];
}

- (void)refreshIfRepositoryChangedSinceLastActivation
{
	[self ensureFocusRefreshCoordinator];
	[_focusRefreshCoordinator applicationDidBecomeActive];
}

- (void)removeAllContentSubViews
{
	while (contentSplitView.subviews.count > 0) [contentSplitView.subviews.lastObject removeFromSuperviewWithoutNeedingDisplay];
}

- (void)changeContentController:(PBViewController *)controller
{
	if (!controller || contentController == controller) return;
	CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
	PBViewController *previousController = contentController;
	if (previousController) {
		NSResponder *firstResponder = self.window.firstResponder;
		if ([firstResponder isKindOfClass:NSView.class] &&
			[(NSView *)firstResponder isDescendantOf:previousController.view]) {
			[_contentFirstResponders setObject:firstResponder forKey:previousController];
		}
		[previousController removeObserver:self keyPath:@"status"];
		previousController.view.hidden = YES;
	}

	contentController = controller;
	BOOL firstMount = controller.view.superview != contentSplitView;
	if (firstMount) {
		controller.view.frame = contentSplitView.bounds;
		controller.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[contentSplitView addSubview:controller.view];
		[controller updateView];
	}
	controller.view.hidden = NO;
	NSResponder *firstResponder = [_contentFirstResponders objectForKey:controller] ?: controller.firstResponder;
	if (firstResponder) [self.window makeFirstResponder:firstResponder];
	[_repositoryToolbarController setHistoryMode:controller == _historyViewController];
	__weak typeof(self) weakSelf = self;
	[controller addObserver:self
					keyPath:@"status"
					options:NSKeyValueObservingOptionInitial
					  block:^(__unused MAKVONotification *note) {
						  [weakSelf updateStatus];
					  }];
	CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - start;
	NSLog(@"[GitX][Performance] %@ repository view in %.3f ms (first mount: %@, budget: %.0f ms)",
		  firstMount ? @"Cold-mounted" : @"Warm-switched",
		  elapsed * 1000.0,
		  firstMount ? @"yes" : @"no",
		  [PBPerformanceBudgets warmViewSwitchP95Seconds] * 1000.0);
}

- (void)showCommitView:(id)sender
{
	NSLog(@"Switching repository window to Commit view");
	[_sidebarController selectStage];
	[self changeContentController:_commitViewController];
}
- (void)showHistoryView:(id)sender
{
	NSLog(@"Switching repository window to History view");
	[_sidebarController selectCurrentBranch];
	[self changeContentController:_historyViewController];
}

- (BOOL)isShowingCommitView
{
	return contentController == _commitViewController;
}

- (void)updateStatus
{
	NSString *status = contentController.status;
	BOOL busy = contentController.isBusy;
	if (!status) {
		status = @"";
		busy = NO;
	}
	statusField.stringValue = status;
	NSString *baseTitle = self.document.displayName ?: self.window.title;
	[_repositoryToolbarController updateWithStatus:status busy:busy baseWindowTitle:baseTitle];
	if (busy) {
		[progressIndicator startAnimation:self];
		progressIndicator.hidden = NO;
	} else {
		[progressIndicator stopAnimation:self];
		progressIndicator.hidden = YES;
	}
}

- (void)setHistorySearch:(NSString *)searchString mode:(PBHistorySearchMode)mode
{
	[_historyViewController setHistorySearch:searchString mode:mode];
}

- (NSArray<NSURL *> *)selectedURLsFromSender:(id)sender
{
	[self ensureActionCoordinators];
	return [_workspaceActionCoordinator selectedURLsFromRepresentedObject:[sender representedObject]];
}

- (void)openURLs:(NSArray<NSURL *> *)fileURLs
{
	[self ensureActionCoordinators];
	[_workspaceActionCoordinator openURLs:fileURLs ?: @[]];
}

- (void)revealURLsInFinder:(NSArray<NSURL *> *)fileURLs
{
	[self ensureActionCoordinators];
	[_workspaceActionCoordinator revealURLsInFinder:fileURLs ?: @[]];
}

- (id<PBGitRefish>)refishForSender:(id)sender refishTypes:(NSArray<NSString *> *)types
{
	[self ensureActionCoordinators];
	BOOL menuSender = [sender isKindOfClass:NSMenuItem.class];
	id representedObject = menuSender ? [sender representedObject] : nil;
	PBGitCommit *selectedCommit = menuSender ? nil : _historyViewController.selectedCommits.firstObject;
	return [_actionContextResolver refishForRepresentedObject:representedObject selectedCommit:selectedCommit allowedTypes:types repository:self.repository];
}

- (PBGitRef *)selectedRef
{
	[self ensureActionCoordinators];
	id firstResponder = self.window.firstResponder;
	PBGitRef *sidebarRef = nil;
	NSString *sidebarRemoteName = nil;
	NSArray<PBGitRef *> *historyRefs = nil;
	if (firstResponder == self.sidebarViewController.sourceView) {
		PBSourceViewItem *item = [self.sidebarViewController.sourceView itemAtRow:self.sidebarViewController.sourceView.selectedRow];
		if (item.parent == self.sidebarViewController.remotes)
			sidebarRemoteName = item.title;
		else
			sidebarRef = item.ref;
	} else if (firstResponder == _historyViewController.commitList && _historyViewController.singleCommitSelected) {
		historyRefs = _historyViewController.selectedCommits.firstObject.refs;
	}
	return [_actionContextResolver selectedRefWithSidebarRef:sidebarRef sidebarRemoteName:sidebarRemoteName historyRefs:historyRefs];
}

- (void)performFetchForRef:(PBGitRef *)ref
{
	[self ensureActionCoordinators];
	[_remoteActionCoordinator performFetchForRef:ref];
}
- (void)performPullForBranch:(PBGitRef *)branch remote:(PBGitRef *)remote rebase:(BOOL)rebase
{
	[self ensureActionCoordinators];
	[_remoteActionCoordinator performPullForBranch:branch remote:remote rebase:rebase];
}
- (void)performPushForBranch:(PBGitRef *)branch toRemote:(PBGitRef *)remote
{
	[self performPushForBranch:branch toRemote:remote requiresConfirmation:YES];
}
- (void)performPushForBranch:(PBGitRef *)branch toRemote:(PBGitRef *)remote requiresConfirmation:(BOOL)confirm
{
	[self ensureActionCoordinators];
	[_remoteActionCoordinator performPushForBranch:branch remote:remote requiresConfirmation:confirm];
}

- (IBAction)showAddRemoteSheet:(id)sender
{
	[self addRemote:sender];
}
- (IBAction)addRemote:(id)sender
{
	[self ensureActionCoordinators];
	[_remoteActionCoordinator addRemote];
}
- (IBAction)fetchRemote:(id)sender
{
	id ref = [self refishForSender:sender refishTypes:@[ kGitXBranchType, kGitXRemoteType ]];
	if ([ref isKindOfClass:PBGitRef.class]) [self performFetchForRef:ref];
}
- (IBAction)fetchAllRemotes:(id)sender
{
	[self performFetchForRef:nil];
}

- (IBAction)pullRemote:(id)sender
{
	[self pullFromSender:sender rebase:NO];
}
- (IBAction)pullRebaseRemote:(id)sender
{
	[self pullFromSender:sender rebase:YES];
}
- (IBAction)pullDefaultRemote:(id)sender
{
	[self pullFromSender:sender rebase:NO];
}
- (IBAction)pullRebaseDefaultRemote:(id)sender
{
	[self pullFromSender:sender rebase:YES];
}
- (void)pullFromSender:(id)sender rebase:(BOOL)rebase
{
	id ref = [self refishForSender:sender refishTypes:@[ kGitXBranchType ]];
	if ([ref isKindOfClass:PBGitRef.class]) [self performPullForBranch:ref remote:nil rebase:rebase];
}
- (IBAction)pushUpdatesToRemote:(id)sender
{
	PBGitRef *ref = (id)[self refishForSender:sender refishTypes:@[ kGitXRemoteType ]];
	if ([ref isKindOfClass:PBGitRef.class]) [self performPushForBranch:nil toRemote:ref.remoteRef];
}
- (IBAction)pushDefaultRemoteForRef:(id)sender
{
	PBGitRef *ref = (id)[self refishForSender:sender refishTypes:@[ kGitXBranchType ]];
	if ([ref isKindOfClass:PBGitRef.class]) [self performPushForBranch:ref toRemote:nil];
}
- (IBAction)pushToRemote:(id)sender
{
	if (![sender isKindOfClass:NSMenuItem.class]) return;
	id ref = [self refishForSender:[sender parentItem] refishTypes:nil];
	id remote = [self refishForSender:sender refishTypes:@[ kGitXRemoteType ]];
	if ([ref isKindOfClass:PBGitRef.class] && [remote isKindOfClass:PBGitRef.class] && [PBReferenceActionPolicy canPushRefishTypeToNamedRemote:[ref refishType]]) [self performPushForBranch:ref toRemote:remote];
}

- (IBAction)checkout:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator checkoutRefish:[self refishForSender:sender refishTypes:@[ kGitXBranchType, kGitXRemoteBranchType, kGitXCommitType, kGitXTagType ]]];
}
- (IBAction)merge:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator mergeRefish:[self refishForSender:sender refishTypes:@[ kGitXBranchType, kGitXRemoteBranchType, kGitXCommitType, kGitXTagType ]]];
}
- (IBAction)rebase:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator rebaseOnRefish:[self refishForSender:sender refishTypes:@[ kGitXCommitType ]]];
}
- (IBAction)rebaseHeadBranch:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator rebaseOnRefish:[self refishForSender:sender refishTypes:@[ kGitXCommitType, kGitXBranchType, kGitXRemoteBranchType ]]];
}
- (IBAction)cherryPick:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator cherryPickRefish:[self refishForSender:sender refishTypes:@[ kGitXCommitType ]]];
}
- (IBAction)resetSoft:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator resetSoftToRefish:[self refishForSender:sender refishTypes:@[ kGitXBranchType, kGitXCommitType ]]];
}
- (IBAction)deleteRef:(id)sender
{
	[self ensureActionCoordinators];
	id ref = [self refishForSender:sender refishTypes:nil];
	[_referenceActionCoordinator deleteRef:[ref isKindOfClass:PBGitRef.class] ? ref : nil];
}
- (IBAction)createBranch:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator createBranchFromRefish:[self refishForSender:sender refishTypes:nil] selectedCommit:_historyViewController.selectedCommits.firstObject];
}
- (IBAction)createTag:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator createTagFromRefish:[self refishForSender:sender refishTypes:nil] selectedCommit:_historyViewController.selectedCommits.firstObject];
}
- (IBAction)diffWithHEAD:(id)sender
{
	[self ensureActionCoordinators];
	[_referenceActionCoordinator showDiffWithHEADForRefish:[self refishForSender:sender refishTypes:nil]];
}
- (IBAction)stashViewDiff:(id)sender
{
	[self ensureActionCoordinators];
	PBGitRef *ref = (id)[self refishForSender:sender refishTypes:@[ kGitXStashType ]];
	[_referenceActionCoordinator showStashDiff:[ref isKindOfClass:PBGitRef.class] ? [self.repository stashForRef:ref] : nil];
}
- (IBAction)showTagInfoSheet:(id)sender
{
	[self ensureActionCoordinators];
	id ref = [self refishForSender:sender refishTypes:@[ kGitXTagType ]];
	[_referenceActionCoordinator showTagInfoForRef:[ref isKindOfClass:PBGitRef.class] ? ref : nil];
}

- (IBAction)stashSave:(id)sender
{
	[self ensureActionCoordinators];
	[_stashActionCoordinator saveWithKeepIndex:NO];
}
- (IBAction)stashSaveWithKeepIndex:(id)sender
{
	[self ensureActionCoordinators];
	[_stashActionCoordinator saveWithKeepIndex:YES];
}
- (IBAction)stashPop:(id)sender
{
	[self ensureActionCoordinators];
	id ref = [self refishForSender:sender refishTypes:@[ kGitXStashType ]];
	[_stashActionCoordinator popRef:[ref isKindOfClass:PBGitRef.class] ? ref : nil];
}
- (IBAction)stashApply:(id)sender
{
	[self ensureActionCoordinators];
	id ref = [self refishForSender:sender refishTypes:@[ kGitXStashType ]];
	[_stashActionCoordinator applyRef:[ref isKindOfClass:PBGitRef.class] ? ref : nil];
}
- (IBAction)stashDrop:(id)sender
{
	[self ensureActionCoordinators];
	id ref = [self refishForSender:sender refishTypes:@[ kGitXStashType ]];
	[_stashActionCoordinator dropRef:[ref isKindOfClass:PBGitRef.class] ? ref : nil];
}

- (IBAction)openFiles:(id)sender
{
	[self openURLs:[self selectedURLsFromSender:sender]];
}
- (IBAction)revealInFinder:(id)sender
{
	// Honor the file paths attached to a menu item (e.g. the history file tree's context menu) the same way
	// openInTerminal: does; fall back to the repository root when the sender carries no selection (e.g. a
	// toolbar/menu action with no represented files).
	NSArray<NSURL *> *urls = nil;
	if ([sender respondsToSelector:@selector(representedObject)])
		urls = [self selectedURLsFromSender:sender];
	if (urls.count == 0) {
		[self ensureActionCoordinators];
		[_workspaceActionCoordinator revealRepositoryInFinder];
		return;
	}
	[self revealURLsInFinder:urls];
}
- (IBAction)openInTerminal:(id)sender
{
	[self ensureActionCoordinators];
	[_workspaceActionCoordinator openRepositoryInTerminal];
}
- (IBAction)refresh:(id)sender
{
	[contentController refresh:self];
	[self synchronizeWindowTitleWithDocumentName];
	NSLog(@"[GitX] Manual refresh synchronized window title: %@", self.window.title);
}
- (IBAction)jumpToCheckedOutBranch:(id)sender
{
	NSLog(@"[GitX] Jumping to the repository's checked-out branch");
	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	[_sidebarController selectCurrentBranch];
}

@end
#pragma clang diagnostic pop

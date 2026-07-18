//
//  PBGitHistoryView.m
//  GitX
//
//  Created by Pieter de Bie on 19-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Quartz/Quartz.h>

#import "PBGitHistoryController.h"
#import "PBGitTree.h"
#import "PBGitRef.h"
#import "PBGitHistoryList.h"
#import "PBGitRevSpecifier.h"
#import "PBWebHistoryController.h"
#import "PBGitGradientBarView.h"
#import "PBDiffWindowController.h"
#import "PBGitDefaults.h"
#import "PBHistorySearchController.h"
#import "PBGitRepositoryWatcher.h"
#import "PBQLTextView.h"
#import "GLFileView.h"
#import "GitXCommitCopier.h"
#import "NSSplitView+GitX.h"
#import "PBGitRevisionRow.h"
#import "PBGitRevisionCell.h"
#import "PBGitStash.h"
#import "PBUncommittedChanges.h"
#import "PBGitIndex.h"
#import "GitX-Swift.h"

#define kHistorySelectedDetailIndexKey @"PBHistorySelectedDetailIndex"
#define kHistoryDetailViewIndex 0
#define kHistoryTreeViewIndex 1

@interface PBGitHistoryController () {
	IBOutlet NSArrayController *commitController;
	IBOutlet NSTreeController *treeController;
	IBOutlet PBWebHistoryController *webHistoryController;
	IBOutlet GLFileView *fileView;
	IBOutlet PBHistorySearchController *searchController;

	__weak IBOutlet NSSearchField *searchField;
	__weak IBOutlet NSOutlineView *fileBrowser;
	__weak IBOutlet PBCommitList *commitList;
	__weak IBOutlet NSSplitView *historySplitView;
	__weak IBOutlet PBGitGradientBarView *upperToolbarView;
	__weak IBOutlet PBGitGradientBarView *scopeBarView;
	__weak IBOutlet NSButton *allBranchesFilterItem;
	__weak IBOutlet NSButton *localRemoteBranchesFilterItem;
	__weak IBOutlet NSButton *selectedBranchFilterItem;

	NSInteger selectedCommitDetailsIndex;
	BOOL forceSelectionUpdate;
	PBGitTree *gitTree;
	NSArray<PBGitCommit *> *webCommits;
	NSArray<PBGitCommit *> *selectedCommits;
	PBUncommittedChanges *uncommittedChanges;
	PBHistoryStateCoordinator *stateCoordinator;
	PBHistoryTreePresentation *treePresentation;
	PBHistoryMenuBuilder *menuBuilder;
	PBHistoryTableInteractionCoordinator *tableInteractionCoordinator;
}

- (void)updateBranchFilterMatrix;
- (void)restoreFileBrowserSelection;
- (void)saveFileBrowserSelection;
- (void)updateUncommittedChanges;

@end


#pragma clang diagnostic push
// Public façade methods implemented in the PBFacadeUI category remain part of
// this runtime class; splitting the source keeps the nib-owning implementation focused.
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation PBGitHistoryController
@synthesize webCommits, gitTree, commitController;
@synthesize searchController;
@synthesize commitList;
@synthesize treeController;
@synthesize selectedCommits;

- (void)awakeFromNib
{
	/* FIXME: Be careful with this method: since PBGitRevisionRow & PBGitRevisionCell
	 * have this controller in their outlets, this method is called *really* often
	 * (vs. the expected *once*)
	 */
}

- (void)loadView
{
	[super loadView];

	[historySplitView pb_restoreAutosavedPositions];

	self.selectedCommitDetailsIndex = [[NSUserDefaults standardUserDefaults] integerForKey:kHistorySelectedDetailIndexKey];

	PBGitRepository *repository = self.repository;
	stateCoordinator = [PBHistoryStateCoordinator new];
	treePresentation = [[PBHistoryTreePresentation alloc] initWithRepository:repository];
	menuBuilder = [[PBHistoryMenuBuilder alloc] initWithRepository:repository];
	tableInteractionCoordinator = [[PBHistoryTableInteractionCoordinator alloc] initWithOwner:self commitList:commitList stateCoordinator:stateCoordinator];
	commitList.delegate = tableInteractionCoordinator;
	commitList.dataSource = tableInteractionCoordinator;

	[commitController addObserver:self
						  keyPath:@"selection"
						  options:0
							block:^(MAKVONotification *notification) {
								PBGitHistoryController *observer = notification.observer;
								[observer updateKeys];
							}];

	[commitController addObserver:self
						  keyPath:@"arrangedObjects.@count"
						  options:NSKeyValueObservingOptionInitial
							block:^(MAKVONotification *notification) {
								PBGitHistoryController *observer = notification.observer;
								[observer reselectCommitAfterUpdate];
							}];

	[treeController addObserver:self
						keyPath:@"selection"
						options:0
						  block:^(MAKVONotification *notification) {
							  PBGitHistoryController *observer = notification.observer;
							  [observer updateQuicklookForce:NO];
							  [observer saveFileBrowserSelection];
						  }];

	[repository.revisionList addObserver:self
								 keyPath:@"isUpdating"
								 options:0
								   block:^(MAKVONotification *notification) {
									   PBGitHistoryController *observer = notification.observer;
									   [observer reselectCommitAfterUpdate];
								   }];

	[repository addObserver:self
					keyPath:@"currentBranch"
					options:0
					  block:^(MAKVONotification *notification) {
						  PBGitHistoryController *observer = notification.observer;
						  observer->forceSelectionUpdate = YES;
						  // Reset the sorting
						  if ([[observer.commitController sortDescriptors] count]) {
							  [observer.commitController setSortDescriptors:[NSArray array]];
							  [observer.commitController rearrangeObjects];
						  }

						  [observer updateBranchFilterMatrix];
					  }];

	[repository addObserver:self
					keyPath:@"refs"
					options:0
					  block:^(MAKVONotification *notification) {
						  PBGitHistoryController *observer = notification.observer;
						  [observer.commitController rearrangeObjects];
					  }];

	[repository addObserver:self
					keyPath:@"currentBranchFilter"
					options:0
					  block:^(MAKVONotification *notification) {
						  PBGitHistoryController *observer = notification.observer;
						  [PBGitDefaults setBranchFilter:observer.repository.currentBranchFilter];
						  [observer updateBranchFilterMatrix];
					  }];

	forceSelectionUpdate = YES;
	NSSize cellSpacing = [commitList intercellSpacing];
	cellSpacing.height = 0;
	[commitList setIntercellSpacing:cellSpacing];
	commitList.allowsMultipleSelection = YES;
	commitList.accessibilityIdentifier = @"CommitList";
	[fileBrowser setTarget:self];
	[fileBrowser setDoubleAction:@selector(openSelectedFile:)];
	fileBrowser.delegate = (id<NSOutlineViewDelegate>)self;
	fileBrowser.allowsMultipleSelection = YES;
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(historyTreeSettingsDidChange:)
												 name:@"PBHistoryTreeSettingsDidChangeNotification"
											   object:nil];

	if (!repository.currentBranch) {
		[repository reloadRefs];
		[repository readCurrentBranch];
	} else
		[repository lazyReload];

	if (![repository hasSVNRemote]) {
		// Remove the SVN revision table column for repositories with no SVN remote configured
		[commitList removeTableColumn:[commitList tableColumnWithIdentifier:@"GitSVNRevision"]];
	}

	// Set a sort descriptor for the subject column in the history list, as
	// It can't be sorted by default (because it's bound to a PBGitCommit)
	[[commitList tableColumnWithIdentifier:@"SubjectColumn"] setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"subject" ascending:YES]];
	// Add a menu that allows a user to select which columns to view
	[[commitList headerView] setMenu:[self tableColumnMenu]];

	[commitList registerForDraggedTypes:[NSArray arrayWithObject:@"PBGitRef"]];

	commitList.target = tableInteractionCoordinator;
	commitList.doubleAction = @selector(didDoubleClickCommitList:);

	[upperToolbarView setTopShade:237 / 255.0f bottomShade:216 / 255.0f];
	[scopeBarView setTopColor:[NSColor colorWithCalibratedHue:0.579 saturation:0.068 brightness:0.898 alpha:1.000]
				  bottomColor:[NSColor colorWithCalibratedHue:0.579 saturation:0.119 brightness:0.765 alpha:1.000]];
	[self updateBranchFilterMatrix];

	// listen for updates
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_repositoryUpdatedNotification:) name:PBGitRepositoryEventNotification object:repository];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(indexUpdated:) name:PBGitIndexIndexUpdated object:repository.index];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(historySortingPreferenceChanged:) name:PBGitHistorySortingPreferenceDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(historyTraversalSettingsDidChange:)
												 name:@"PBHistoryTraversalSettingsDidChangeNotification"
											   object:nil];
	[self updateUncommittedChanges];

	[super awakeFromNib];
}

- (void)indexUpdated:(NSNotification *)notification
{
	[self updateUncommittedChanges];
}

- (void)historySortingPreferenceChanged:(NSNotification *)notification
{
	if (![PBGitDefaults historyColumnSortingEnabled]) commitController.sortDescriptors = @[];
	[commitController rearrangeObjects];
	[commitList reloadData];
}

- (void)historyTraversalSettingsDidChange:(NSNotification *)notification
{
	NSLog(@"[GitX] History traversal setting changed; reloading revisions");
	[self.repository forceUpdateRevisions];
}

- (void)updateUncommittedChanges
{
	BOOL wasSelected = [self.selectedCommits.firstObject isKindOfClass:PBUncommittedChanges.class];
	BOOL isDirty = self.repository.index.indexChanges.count > 0;
	if (isDirty) {
		if (!uncommittedChanges) {
			uncommittedChanges = [[PBUncommittedChanges alloc] initWithRepository:self.repository];
			((PBHistoryArrayController *)commitController).pinnedObject = uncommittedChanges;
			if (wasSelected) [commitController setSelectedObjects:@[ uncommittedChanges ]];
		} else {
			[uncommittedChanges refreshFromRepository];
			NSArray *arrangedCommits = commitController.arrangedObjects;
			NSUInteger row = [arrangedCommits indexOfObjectIdenticalTo:uncommittedChanges];
			if (row != NSNotFound)
				[commitList reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, commitList.numberOfColumns)]];
			if (wasSelected) {
				if (self.selectedCommitDetailsIndex == kHistoryTreeViewIndex)
					[self updateKeys];
				else
					[webHistoryController refreshDisplayedContent];
			}
		}
	} else {
		uncommittedChanges = nil;
		((PBHistoryArrayController *)commitController).pinnedObject = nil;
		if (wasSelected) {
			PBGitCommit *newest = self.firstCommit;
			[commitController setSelectedObjects:newest ? @[ newest ] : @[]];
		}
	}
	tableInteractionCoordinator.hasWorkingState = uncommittedChanges != nil;
	[self updateStatus];
}

- (void)_repositoryUpdatedNotification:(NSNotification *)notification
{
	PBGitRepositoryWatcherEventType eventType = [(NSNumber *)[[notification userInfo] objectForKey:kPBGitRepositoryEventTypeUserInfoKey] unsignedIntValue];
	if (eventType & PBGitRepositoryWatcherEventTypeGitDirectory) {
		// refresh if the .git repository is modified
		[self refresh:self];
	}
}

- (void)reselectCommitAfterUpdate
{
	[self updateStatus];
	if ([self.selectedCommits.firstObject isKindOfClass:PBUncommittedChanges.class] && uncommittedChanges) {
		[commitController setSelectedObjects:@[ uncommittedChanges ]];
		return;
	}
	if (!forceSelectionUpdate && self.selectedCommits.count) {
		NSArray<PBGitCommit *> *preservedSelection = [stateCoordinator preservedSelection:self.selectedCommits inContent:commitController.content];
		if (preservedSelection) {
			[commitController setSelectedObjects:preservedSelection];
			return;
		}
	}

	if ([self.repository.currentBranch isSimpleRef])
		[self selectCommit:[self.repository OIDForRef:self.repository.currentBranch.ref]];
	else
		[self selectCommit:self.firstCommit.OID];
}

- (void)updateKeys
{
	NSArray<PBGitCommit *> *newSelectedCommits = [stateCoordinator normalizedSelection:commitController.selectedObjects];
	if (![newSelectedCommits isEqualToArray:commitController.selectedObjects])
		[commitController setSelectedObjects:newSelectedCommits];
	if (![self.selectedCommits isEqualToArray:newSelectedCommits]) {
		self.selectedCommits = newSelectedCommits;
	}

	PBGitCommit *firstSelectedCommit = self.selectedCommits.firstObject;
	if (!firstSelectedCommit) {
		self.gitTree = nil;
		if (self.webCommits.count) self.webCommits = @[];
		return;
	}
	self.selectedCommitDetailsIndex = [stateCoordinator detailIndexForCurrentIndex:self.selectedCommitDetailsIndex selectionCount:self.selectedCommits.count];

	if (self.selectedCommitDetailsIndex == kHistoryTreeViewIndex) {
		self.gitTree = [treePresentation treeForCommit:firstSelectedCommit];
		[self restoreFileBrowserSelection];
	} else {
		// kHistoryDetailViewIndex
		if (![self.webCommits isEqualToArray:self.selectedCommits]) {
			self.webCommits = self.selectedCommits;
		}
	}
}

- (void)historyTreeSettingsDidChange:(NSNotification *)notification
{
	if (self.selectedCommitDetailsIndex != kHistoryTreeViewIndex) return;
	PBGitCommit *commit = self.selectedCommits.firstObject;
	if (!commit) return;
	self.gitTree = [treePresentation treeForCommit:commit];
	[self restoreFileBrowserSelection];
}

- (void)outlineView:(NSOutlineView *)outlineView
	willDisplayCell:(NSTextFieldCell *)cell
	 forTableColumn:(NSTableColumn *)tableColumn
			   item:(id)item
{
	if (outlineView != fileBrowser || ![item isKindOfClass:NSTreeNode.class]) return;
	PBGitTree *tree = [(NSTreeNode *)item representedObject];
	if (![tree isKindOfClass:PBGitTree.class]) return;
	cell.stringValue = [treePresentation displayTitleForTree:tree];
	cell.lineBreakMode = NSLineBreakByTruncatingHead;
}

- (NSString *)outlineView:(NSOutlineView *)outlineView
		   toolTipForCell:(NSCell *)cell
					 rect:(NSRectPointer)rect
			  tableColumn:(NSTableColumn *)tableColumn
					 item:(id)item
			mouseLocation:(NSPoint)mouseLocation
{
	if (outlineView != fileBrowser || ![item isKindOfClass:NSTreeNode.class]) return nil;
	PBGitTree *tree = [(NSTreeNode *)item representedObject];
	return [tree isKindOfClass:PBGitTree.class] ? [treePresentation toolTipForTree:tree] : nil;
}

- (BOOL)singleCommitSelected
{
	return self.selectedCommits.count == 1 && ![self.selectedCommits.firstObject isKindOfClass:PBUncommittedChanges.class];
}

+ (NSSet *)keyPathsForValuesAffectingSingleCommitSelected
{
	return [NSSet setWithObjects:@"selectedCommits", nil];
}

- (BOOL)singleNonHeadCommitSelected
{
	return self.singleCommitSelected && ![self.selectedCommits.firstObject isOnHeadBranch];
}

+ (NSSet *)keyPathsForValuesAffectingSingleNonHeadCommitSelected
{
	return [self keyPathsForValuesAffectingSingleCommitSelected];
}

- (void)updateBranchFilterMatrix
{
	PBGitRepository *repository = self.repository;
	PBHistoryBranchFilterPresentation *presentation = [stateCoordinator branchFilterPresentationForSimpleBranch:repository.currentBranch.isSimpleRef
																										 filter:repository.currentBranchFilter
																								  selectedTitle:repository.currentBranch.title ?: @""
																										 remote:repository.currentBranch.ref.isRemote];
	allBranchesFilterItem.enabled = presentation.allEnabled;
	localRemoteBranchesFilterItem.enabled = presentation.localEnabled;
	allBranchesFilterItem.state = presentation.allState;
	localRemoteBranchesFilterItem.state = presentation.localState;
	selectedBranchFilterItem.state = presentation.selectedState;
	selectedBranchFilterItem.title = presentation.selectedTitle;
	[selectedBranchFilterItem sizeToFit];
	localRemoteBranchesFilterItem.title = presentation.localTitle;
}

- (PBGitCommit *)firstCommit
{
	NSArray *arrangedObjects = [commitController arrangedObjects];
	for (PBGitCommit *commit in arrangedObjects)
		if (![commit isKindOfClass:PBUncommittedChanges.class]) return commit;

	return nil;
}

- (BOOL)isCommitSelected
{
	return [self.selectedCommits isEqualToArray:[commitController selectedObjects]];
}

- (void)setSelectedCommitDetailsIndex:(NSInteger)detailsIndex
{
	if (selectedCommitDetailsIndex == detailsIndex)
		return;

	selectedCommitDetailsIndex = detailsIndex;
	[[NSUserDefaults standardUserDefaults] setInteger:selectedCommitDetailsIndex forKey:kHistorySelectedDetailIndexKey];
	forceSelectionUpdate = YES;
	[self updateKeys];
}

- (NSInteger)selectedCommitDetailsIndex
{
	return selectedCommitDetailsIndex;
}

- (void)updateStatus
{
	self.isBusy = self.repository.revisionList.isUpdating;
	self.status = [stateCoordinator statusForArrangedCount:[[commitController arrangedObjects] count] hasWorkingState:uncommittedChanges != nil];
}

- (void)restoreFileBrowserSelection
{
	NSIndexPath *path = [stateCoordinator treeSelectionIndexPathForChildren:treeController.content treeMode:self.selectedCommitDetailsIndex == kHistoryTreeViewIndex];
	if (path) [treeController setSelectionIndexPath:path];
}

- (void)saveFileBrowserSelection
{
	[stateCoordinator saveFileBrowserSelectionFromSelectedObjects:treeController.selectedObjects hasContent:[treeController.content count] > 0];
}

- (IBAction)setDetailedView:(id)sender
{
	self.selectedCommitDetailsIndex = kHistoryDetailViewIndex;
	forceSelectionUpdate = YES;
}

- (IBAction)setTreeView:(id)sender
{
	self.selectedCommitDetailsIndex = kHistoryTreeViewIndex;
	forceSelectionUpdate = YES;
}

- (IBAction)setBranchFilter:(id)sender
{
	PBGitRepository *repository = self.repository;

	repository.currentBranchFilter = [(NSView *)sender tag];
	[PBGitDefaults setBranchFilter:repository.currentBranchFilter];
	[self updateBranchFilterMatrix];
	forceSelectionUpdate = YES;
}

- (void)keyDown:(NSEvent *)event
{
	if ([[event charactersIgnoringModifiers] isEqualToString:@"f"] && [event modifierFlags] & NSEventModifierFlagOption && [event modifierFlags] & NSEventModifierFlagCommand)
		[self.windowController.window makeFirstResponder:searchField];
	else
		[super keyDown:event];
}

- (IBAction)performFindPanelAction:(id)sender
{
	[self.windowController.window makeFirstResponder:self->searchField];
}

// NSSearchField (actually textfields in general) prevent the normal Find operations from working. Setup custom actions for the
// next and previous menuitems (in MainMenu.nib) so they will work when the search field is active. When searching for text in
// a file make sure to call the Find panel's action method instead.
- (void)scrollSelectionToTopOfViewFrom:(NSInteger)oldIndex
{
	if (oldIndex == NSNotFound)
		oldIndex = 0;

	NSInteger newIndex = commitController.selectionIndexes.firstIndex;
	NSInteger visibleRows = lround(commitList.superview.bounds.size.height / commitList.rowHeight);
	newIndex = [stateCoordinator adjustedScrollRowForSelectionRow:newIndex oldRow:oldIndex visibleRows:visibleRows contentCount:[commitController.content count]];

	if (newIndex != oldIndex) {
		commitList.useAdjustScroll = YES;
	}

	[commitList scrollRowToVisible:newIndex];
	commitList.useAdjustScroll = NO;
}

- (NSArray *)selectedObjectsForOID:(GTOID *)commitOID
{
	return [stateCoordinator selectedObjectsForOID:commitOID content:commitController.content fallback:self.firstCommit];
}

- (void)selectCommit:(GTOID *)commitOID
{
	if (!forceSelectionUpdate && [[[commitController.selectedObjects lastObject] OID] isEqual:commitOID]) {
		return;
	}

	NSArray *selectedObjects = [self selectedObjectsForOID:commitOID];
	[commitController setSelectedObjects:selectedObjects];

	NSInteger oldIndex = [[commitController selectionIndexes] firstIndex];
	[self scrollSelectionToTopOfViewFrom:oldIndex];

	forceSelectionUpdate = NO;
}

- (void)closeView
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	[webHistoryController closeView];
	[fileView closeView];

	[super closeView];
}

#pragma mark Table Column Methods

@end
#pragma clang diagnostic pop

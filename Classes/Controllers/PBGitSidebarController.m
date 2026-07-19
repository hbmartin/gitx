//
//  PBGitSidebar.m
//  GitX
//
//  Created by Pieter de Bie on 9/8/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "PBGitSidebarController.h"
#import "PBSourceViewItems.h"
#import "PBGitHistoryController.h"
#import "PBGitCommitController.h"
#import "NSOutlineViewExt.h"
#import "PBAddRemoteSheet.h"
#import "PBGitDefaults.h"
#import "PBHistorySearchController.h"
#import "PBGitStash.h"
#import "PBSourceViewGitStashItem.h"
#import "PBSidebarTableViewCell.h"
#import "PBGitRef.h"
#import "GitX-Swift.h"

#define PBSidebarCellIdentifier @"PBSidebarCellIdentifier"
#define PBBranchesHeaderCellIdentifier @"PBBranchesHeaderCellIdentifier"

@interface PBGitSidebarController () <NSOutlineViewDelegate> {
	__weak IBOutlet NSWindow *window;
	__weak IBOutlet NSOutlineView *sourceView;
	__weak IBOutlet NSView *sourceListControlsView;
	__weak IBOutlet NSPopUpButton *actionButton;
	__weak IBOutlet NSSegmentedControl *remoteControls;

	NSMutableArray *items;

	/* Specific things */
	PBSourceViewItem *stage;

	PBSourceViewItem *branches, *remotes, *tags, *others, *submodules, *stashes;
	PBBranchSidebarPresentation *branchPresentation;
}

- (void)populateList;
- (PBSourceViewItem *)addRevSpec:(PBGitRevSpecifier *)revSpec;
- (PBSourceViewItem *)itemForRev:(PBGitRevSpecifier *)rev;
- (void)removeRevSpec:(PBGitRevSpecifier *)rev;
- (void)updateActionMenu;
- (void)updateRemoteControls;
- (void)reloadSidebarAfterReferencesChange;
- (void)reloadSidebarPresentation;
- (void)synchronizeConfiguredRemotes;
- (NSArray<PBSourceViewItem *> *)visibleChildrenForItem:(PBSourceViewItem *)item;

@property (nonatomic) PBGitRevSpecifier *lastKnownHeadRef;
@end

@implementation PBGitSidebarController
@synthesize items;
@synthesize remotes;
@synthesize sourceView;
@synthesize sourceListControlsView;

- (instancetype)initWithRepository:(PBGitRepository *)theRepository superController:(PBGitWindowController *)controller
{
	self = [super initWithRepository:theRepository superController:controller];
	if (!self) return nil;

	[sourceView setDelegate:self];
	items = [NSMutableArray array];
	branchPresentation = [[PBBranchSidebarPresentation alloc] initWithRepository:theRepository];

	return self;
}

- (void)awakeFromNib
{
	[super awakeFromNib];
	window.contentView = self.view;
	sourceView.accessibilityIdentifier = @"RepositorySidebar";
	[self populateList];

	PBGitRepository *repository = self.repository;
	self.lastKnownHeadRef = repository.headRef;

	[repository addObserver:self
					keyPath:@"currentBranch"
					options:0
					  block:^(MAKVONotification *notification) {
						  PBGitSidebarController *observer = notification.observer;
						  NSInteger row = observer.sourceView.selectedRow;
						  [observer.sourceView reloadData];
						  if (row >= 0)
							  [observer.sourceView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
						  [observer selectCurrentBranch];
					  }];

	[repository addObserver:self
					keyPath:@"branches"
					options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew)
					  block:^(MAKVONotification *notification) {
						  PBGitSidebarController *observer = notification.observer;
						  [observer reloadSidebarPresentation];
					  }];

	[repository addObserver:self
					keyPath:@"refs"
					options:0
					  block:^(MAKVONotification *notification) {
						  PBGitSidebarController *observer = notification.observer;
						  [observer reloadSidebarAfterReferencesChange];
					  }];

	[repository addObserver:self
					keyPath:@"stashes"
					options:0
					  block:^(MAKVONotification *notification) {
						  PBGitSidebarController *observer = notification.observer;
						  for (PBSourceViewGitStashItem *stashItem in observer->stashes.sortedChildren)
							  [observer->stashes removeChild:stashItem];

						  for (PBGitStash *stash in observer.repository.stashes)
							  [observer->stashes addChild:[PBSourceViewGitStashItem itemWithStash:stash]];

						  [observer.sourceView expandItem:observer->stashes];
						  [observer.sourceView reloadItem:observer->stashes reloadChildren:YES];
					  }];

	[sourceView setTarget:self];
	[sourceView setDoubleAction:@selector(doubleClicked:)];

	[self menuNeedsUpdate:[actionButton menu]];

	if ([PBGitDefaults showStageView])
		[self selectStage];
	else
		[self selectCurrentBranch];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(expandCollapseItem:) name:NSOutlineViewItemWillExpandNotification object:sourceView];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(expandCollapseItem:) name:NSOutlineViewItemWillCollapseNotification object:sourceView];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(repositorySettingsDidChange:) name:@"PBRepositorySettingsDidChangeNotification" object:repository];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(repositorySettingsDidChange:) name:@"PBBranchSidebarSettingsDidChangeNotification" object:nil];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSOutlineViewItemWillExpandNotification object:sourceView];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSOutlineViewItemWillCollapseNotification object:sourceView];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:@"PBRepositorySettingsDidChangeNotification" object:self.repository];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:@"PBBranchSidebarSettingsDidChangeNotification" object:nil];
}

- (void)repositorySettingsDidChange:(NSNotification *)notification
{
	[self reloadSidebarPresentation];
}

- (void)reloadSidebarPresentation
{
	BOOL stageSelected = [PBGitDefaults showStageView];
	PBGitRevSpecifier *viewedRev = self.repository.currentBranch;
	[self populateList];
	if (stageSelected) {
		[self selectStage];
	} else {
		PBSourceViewItem *item = [self itemForRev:viewedRev];
		if (item) {
			[sourceView PBExpandItem:item expandParents:YES];
			NSInteger row = [sourceView rowForItem:item];
			if (row >= 0) [sourceView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		} else {
			[self selectCurrentBranch];
		}
	}
}

- (PBSourceViewItem *)selectedItem
{
	NSInteger index = [sourceView selectedRow];
	PBSourceViewItem *item = [sourceView itemAtRow:index];

	return item;
}

- (void)selectStage
{
	NSInteger row = [sourceView rowForItem:stage];
	if (row < 0) {
		[self selectCurrentBranch];
		return;
	}
	NSIndexSet *index = [NSIndexSet indexSetWithIndex:row];
	[sourceView selectRowIndexes:index byExtendingSelection:NO];
}

- (void)selectCurrentBranch
{
	PBGitRepository *repository = self.repository;
	PBGitRevSpecifier *rev = repository.currentBranch;
	if (!rev) {
		[repository reloadRefs];
		[repository readCurrentBranch];
		return;
	}

	if (@available(macOS 10.12, *))
		dispatch_assert_queue(dispatch_get_main_queue());

	PBSourceViewItem *item = [self addRevSpec:rev];
	if (item) {
		[sourceView PBExpandItem:item expandParents:YES];
		NSInteger row = [sourceView rowForItem:item];
		if (row >= 0) {
			[sourceView deselectAll:nil];
			[sourceView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		}
	}
}

- (PBSourceViewItem *)itemForRev:(PBGitRevSpecifier *)rev
{
	PBSourceViewItem *foundItem = nil;
	for (PBSourceViewItem *item in items)
		if ((foundItem = [item findRev:rev]) != nil)
			return foundItem;
	return nil;
}

- (PBSourceViewItem *)addRevSpec:(PBGitRevSpecifier *)rev
{
	PBSourceViewItem *item = nil;
	for (PBSourceViewItem *it in items)
		if ((item = [it findRev:rev]) != nil)
			return item;

	NSString *simpleReference = [rev isSimpleRef] ? [rev simpleRef] : nil;
	PBSidebarRevisionPlan *plan = [PBSidebarRevisionPolicy planForSimpleReference:simpleReference
																 shouldShowBranch:[branchPresentation shouldShowRevision:rev]
														  usesRecentBranchSorting:branchPresentation.usesRecentSorting];
	switch (plan.placement) {
		case PBSidebarRevisionPlacementOther:
			item = [PBSourceViewItem itemWithRevSpec:rev];
			[others addChild:item];
			return item;
		case PBSidebarRevisionPlacementBranchRoot:
			item = [PBSourceViewItem itemWithRevSpec:rev];
			if ([simpleReference hasPrefix:@"refs/heads/"] && branchPresentation.usesRecentSorting)
				item.title = item.ref.shortName;
			[branches addChild:item];
			break;
		case PBSidebarRevisionPlacementBranchPath:
			[branches addRev:rev toPath:plan.path];
			break;
		case PBSidebarRevisionPlacementTagPath:
			[tags addRev:rev toPath:plan.path];
			break;
		case PBSidebarRevisionPlacementRemotePath:
			[remotes addRev:rev toPath:plan.path];
			break;
		case PBSidebarRevisionPlacementHidden:
			return nil;
		case PBSidebarRevisionPlacementUnsupported:
			break;
	}
	return item ?: [self itemForRev:rev];
}

- (void)reloadSidebarAfterReferencesChange
{
	BOOL stageSelected = [PBGitDefaults showStageView];
	PBGitRevSpecifier *viewedRev = self.repository.currentBranch;
	PBGitRevSpecifier *newHead = self.repository.headRef;
	BOOL followHead = [PBHistoryRefreshSelectionPolicy shouldFollowCheckedOutBranchWithStageSelected:stageSelected
																						   viewedRef:viewedRev.simpleRef
																					 previousHeadRef:self.lastKnownHeadRef.simpleRef];
	if (followHead && newHead && ![viewedRev isEqual:newHead]) {
		self.repository.currentBranch = newHead;
		viewedRev = newHead;
	}

	[self populateList];
	if (stageSelected) {
		[self selectStage];
	} else {
		PBSourceViewItem *item = [self itemForRev:viewedRev];
		if (item) {
			[sourceView PBExpandItem:item expandParents:YES];
			NSInteger row = [sourceView rowForItem:item];
			if (row >= 0)
				[sourceView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		}
	}

	NSLog(@"[GitX] Refreshed sidebar refs: HEAD %@ -> %@, followed=%@, stage=%@",
		  self.lastKnownHeadRef.simpleRef ?: @"(none)", newHead.simpleRef ?: @"(none)",
		  followHead ? @"yes" : @"no", stageSelected ? @"yes" : @"no");
	self.lastKnownHeadRef = newHead;
}

- (void)synchronizeConfiguredRemotes
{
	NSArray<PBSourceViewItem *> *remoteItems = remotes.sortedChildren;
	NSMutableArray<NSString *> *existingNames = [NSMutableArray array];
	NSMutableArray<NSString *> *nonEmptyNames = [NSMutableArray array];
	NSMutableDictionary<NSString *, PBSourceViewItem *> *itemsByName = [NSMutableDictionary dictionary];
	for (PBSourceViewItem *item in remoteItems) {
		if (![item isKindOfClass:[PBSourceViewGitRemoteItem class]]) continue;
		[existingNames addObject:item.title];
		itemsByName[item.title] = item;
		if (item.sortedChildren.count > 0) [nonEmptyNames addObject:item.title];
	}

	NSArray<NSString *> *configuredRemotes = self.repository.remotes ?: @[];
	PBRemoteSidebarSyncPlan *plan = [PBRemoteSidebarSyncPlan planWithConfiguredRemoteNames:configuredRemotes
																	   existingRemoteNames:existingNames
																	   nonEmptyRemoteNames:nonEmptyNames];
	for (NSString *name in plan.namesToAdd) {
		[remotes addChild:[PBSourceViewGitRemoteItem remoteItemWithTitle:name]];
	}
	for (NSString *name in plan.namesToRemove) {
		[remotes removeChild:itemsByName[name]];
	}
	if (plan.namesToAdd.count > 0 || plan.namesToRemove.count > 0) {
		NSLog(@"[GitX] Synchronized configured remotes: added=%@ removed=%@", plan.namesToAdd, plan.namesToRemove);
	}
}

- (void)removeRevSpec:(PBGitRevSpecifier *)rev
{
	PBSourceViewItem *item = [self itemForRev:rev];

	if (!item)
		return;

	PBSourceViewItem *parent = item.parent;
	[parent removeChild:item];
	[sourceView reloadData];
}

- (void)openSubmoduleFromMenuItem:(NSMenuItem *)menuItem
{
	[self openSubmoduleAtURL:[menuItem representedObject]];
}

- (void)openSubmoduleAtURL:(NSURL *)submoduleURL
{
	[[PBRepositoryOpenCoordinator shared] openURLs:@[ submoduleURL ]
									  sourceWindow:self.windowController.window
										completion:^(__unused NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
											for (NSError *error in errors) [self.windowController showErrorSheet:error];
										}];
}

#pragma mark NSOutlineView delegate methods

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	NSInteger index = [sourceView selectedRow];
	PBSourceViewItem *item = [sourceView itemAtRow:index];
	PBGitWindowController *windowController = self.windowController;

	if ([item revSpecifier]) {
		if (![self.repository.currentBranch isEqual:[item revSpecifier]]) {
			self.repository.currentBranch = [item revSpecifier];
		}

		[windowController changeContentController:windowController.historyViewController];
		[PBGitDefaults setShowStageView:NO];
	}

	if (item == stage) {
		[windowController changeContentController:windowController.commitViewController];
		[PBGitDefaults setShowStageView:YES];
	}

	[self updateActionMenu];
	[self updateRemoteControls];
}

- (void)doubleClicked:(id)object
{
	NSInteger rowNumber = [sourceView selectedRow];

	id item = [sourceView itemAtRow:rowNumber];
	if ([item isKindOfClass:[PBSourceViewGitSubmoduleItem class]]) {
		PBSourceViewGitSubmoduleItem *subModule = item;

		[self openSubmoduleAtURL:[subModule path]];
	} else if ([item isKindOfClass:[PBSourceViewGitBranchItem class]]) {
		PBSourceViewGitBranchItem *branch = item;

		NSError *error = nil;
		BOOL success = [self.repository checkoutRefish:[branch ref] error:&error];
		if (!success) {
			[self.windowController showErrorSheet:error];
		}
	}
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldEditTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
	if ([item isKindOfClass:[PBSourceViewGitSubmoduleItem class]]) {
		NSLog(@"hi");
	}
	return NO;
}
#pragma mark NSOutlineView delegate methods
- (BOOL)outlineView:(NSOutlineView *)outlineView isGroupItem:(id)item
{
	return [item isGroupItem];
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(PBSourceViewItem *)item
{
	if (item == branches) {
		NSTableCellView *header = [outlineView makeViewWithIdentifier:PBBranchesHeaderCellIdentifier owner:self];
		if (!header) {
			header = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, outlineView.bounds.size.width, 22)];
			header.identifier = PBBranchesHeaderCellIdentifier;
			NSTextField *label = [NSTextField labelWithString:NSLocalizedString(@"BRANCHES", nil)];
			label.font = [NSFont preferredFontForTextStyle:NSFontTextStyleSubheadline options:@{}];
			label.translatesAutoresizingMaskIntoConstraints = NO;
			header.textField = label;
			[header addSubview:label];
			NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"textformat" accessibilityDescription:NSLocalizedString(@"Change branch sorting", nil)]
												  target:self
												  action:@selector(toggleBranchSort:)];
			button.identifier = @"BranchSortToggle";
			button.bordered = NO;
			button.translatesAutoresizingMaskIntoConstraints = NO;
			[header addSubview:button];
			[NSLayoutConstraint activateConstraints:@[
				[label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor
													constant:4],
				[label.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
				[button.trailingAnchor constraintEqualToAnchor:header.trailingAnchor
													  constant:-4],
				[button.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
			]];
		}
		NSButton *sortButton = nil;
		for (NSView *subview in header.subviews) {
			if ([subview.identifier isEqualToString:@"BranchSortToggle"]) sortButton = (NSButton *)subview;
		}
		sortButton.image = [NSImage imageWithSystemSymbolName:(branchPresentation.usesRecentSorting ? @"clock" : @"textformat") accessibilityDescription:NSLocalizedString(@"Change branch sorting", nil)];
		sortButton.toolTip = branchPresentation.usesRecentSorting ? NSLocalizedString(@"Branches sorted by most recent commit. Click for alphabetical.", nil) : NSLocalizedString(@"Branches sorted alphabetically. Click for most recent commit.", nil);
		return header;
	}
	PBSidebarTableViewCell *cell = [outlineView makeViewWithIdentifier:PBSidebarCellIdentifier owner:outlineView];

	cell.textField.stringValue = [[item title] copy];
	cell.imageView.image = item.icon;
	cell.isCheckedOut = [item.revSpecifier isEqual:[self.repository headRef]];

	return cell;
}

- (void)toggleBranchSort:(id)sender
{
	[branchPresentation toggleSorting];
	NSLog(@"[GitX] Toggled branch sidebar sort mode");
	[[NSNotificationCenter defaultCenter] postNotificationName:@"PBBranchSidebarSettingsDidChangeNotification" object:nil];
}

- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item
{
	NSTableRowView *view = [sourceView rowViewAtRow:[sourceView rowForItem:item] makeIfNecessary:NO];

	if (view) {
		return view;
	}

	return [NSTableRowView new];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item
{
	return ![item isGroupItem];
}

//
// The next method is necessary to hide the triangle for uncollapsible items
// That is, items which should always be displayed, such as the Project group.
// This also moves the group item to the left edge.
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldShowOutlineCellForItem:(id)item
{
	return ![item isUncollapsible];
}

- (void)populateList
{
	PBGitRepository *repository = self.repository;
	[branchPresentation reload];
	[items removeAllObjects];
	PBSourceViewItem *project = [PBSourceViewItem groupItemWithTitle:[repository projectName]];
	project.uncollapsible = YES;

	stage = [PBSourceViewStageItem stageItem];
	PBRepositoryUISettings *uiSettings = [[PBRepositoryUISettings alloc] initWithRepository:repository];
	if ([uiSettings isSidebarGroupVisible:@"Stage"]) [project addChild:stage];

	branches = [PBSourceViewItem groupItemWithTitle:@"Branches"];
	remotes = [PBSourceViewItem groupItemWithTitle:@"Remotes"];
	tags = [PBSourceViewItem groupItemWithTitle:@"Tags"];
	stashes = [PBSourceViewItem groupItemWithTitle:@"Stashes"];
	submodules = [PBSourceViewItem groupItemWithTitle:@"Submodules"];
	others = [PBSourceViewItem groupItemWithTitle:@"Other"];

	for (PBGitStash *stash in repository.stashes)
		[stashes addChild:[PBSourceViewGitStashItem itemWithStash:stash]];

	for (PBGitRevSpecifier *rev in repository.branches) {
		[self addRevSpec:rev];
	}
	[self synchronizeConfiguredRemotes];

	for (GTSubmodule *sub in repository.submodules) {
		[submodules addChild:[PBSourceViewGitSubmoduleItem itemWithSubmodule:sub]];
	}

	[items addObject:project];
	[items addObject:branches];
	if ([uiSettings isSidebarGroupVisible:@"Remotes"]) [items addObject:remotes];
	if ([uiSettings isSidebarGroupVisible:@"Tags"]) [items addObject:tags];
	if ([uiSettings isSidebarGroupVisible:@"Stashes"]) [items addObject:stashes];
	if ([uiSettings isSidebarGroupVisible:@"Submodules"]) [items addObject:submodules];
	if ([uiSettings isSidebarGroupVisible:@"Other"]) [items addObject:others];

	[sourceView reloadData];
	[sourceView expandItem:project];
	[sourceView expandItem:branches expandChildren:YES];
	[sourceView expandItem:remotes];
	[sourceView expandItem:stashes];
	[sourceView expandItem:submodules];

	[sourceView reloadItem:nil reloadChildren:YES];
}

- (void)expandCollapseItem:(NSNotification *)aNotification
{
	NSObject *child = [[aNotification userInfo] valueForKey:@"NSObject"];
	if ([child isKindOfClass:[PBSourceViewItem class]]) {
		((PBSourceViewItem *)child).expanded = [aNotification.name isEqualToString:NSOutlineViewItemWillExpandNotification];
	}
}

#pragma mark NSOutlineView Datasource methods

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
	if (!item)
		return [items objectAtIndex:index];

	return [[self visibleChildrenForItem:(PBSourceViewItem *)item] objectAtIndex:index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	return [[self visibleChildrenForItem:(PBSourceViewItem *)item] count] > 0;
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	if (!item)
		return [items count];

	return [[self visibleChildrenForItem:(PBSourceViewItem *)item] count];
}

- (NSArray<PBSourceViewItem *> *)visibleChildrenForItem:(PBSourceViewItem *)item
{
	NSArray<PBSourceViewItem *> *children = item.sortedChildren;
	return item == branches ? [branchPresentation sortedBranchItems:children] : children;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	return [(PBSourceViewItem *)item title];
}


#pragma mark Menus

- (void)updateActionMenu
{
	[actionButton setEnabled:([[self selectedItem] ref] != nil || [[self selectedItem] isKindOfClass:[PBSourceViewGitSubmoduleItem class]])];
}

- (void)addMenuItemsForRef:(PBGitRef *)ref toMenu:(NSMenu *)menu
{
	if (!ref)
		return;

	for (NSMenuItem *menuItem in [self.windowController.historyViewController menuItemsForRef:ref])
		[menu addItem:menuItem];
}

- (void)addMenuItemsForSubmodule:(PBSourceViewGitSubmoduleItem *)submodule toMenu:(NSMenu *)menu
{
	if (!submodule)
		return;

	NSMenuItem *menuItem = [menu addItemWithTitle:NSLocalizedString(@"Open Submodule", @"Open Submodule menu item") action:@selector(openSubmoduleFromMenuItem:) keyEquivalent:@""];

	[menuItem setTarget:self];
	[menuItem setRepresentedObject:[submodule path]];
}

- (NSMenuItem *)actionIconItem
{
	NSMenuItem *actionIconItem = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
	NSImage *actionIcon = [NSImage imageNamed:@"NSActionTemplate"];
	[actionIcon setSize:NSMakeSize(12, 12)];
	[actionIconItem setImage:actionIcon];

	return actionIconItem;
}

- (NSMenu *)menuForRow:(NSInteger)row
{
	PBSourceViewItem *viewItem = [sourceView itemAtRow:row];
	PBGitRef *ref = [viewItem ref];
	NSMenu *menu = [[NSMenu alloc] init];

	[menu setAutoenablesItems:NO];

	if (ref) {
		[self addMenuItemsForRef:ref toMenu:menu];
	}

	if ([viewItem isKindOfClass:[PBSourceViewGitSubmoduleItem class]]) {
		[self addMenuItemsForSubmodule:(PBSourceViewGitSubmoduleItem *)viewItem toMenu:menu];
	}

	return menu;
}

// delegate of the action menu
- (void)menuNeedsUpdate:(NSMenu *)menu
{
	[menu removeAllItems];
	if (menu == actionButton.menu) [menu addItem:[self actionIconItem]];

	PBGitRef *ref = [[self selectedItem] ref];
	[self addMenuItemsForRef:ref toMenu:menu];

	if ([[self selectedItem] isKindOfClass:[PBSourceViewGitSubmoduleItem class]]) {
		[self addMenuItemsForSubmodule:(PBSourceViewGitSubmoduleItem *)[self selectedItem] toMenu:menu];
	}
}


#pragma mark Remote controls

enum {
	kAddRemoteSegment = 0,
	kFetchSegment = 1,
	kPullSegment = 2,
	kPushSegment = 3
};

- (void)updateRemoteControls
{
	BOOL hasRemote = NO;

	PBGitRef *ref = [[self selectedItem] ref];
	if ([ref isRemote] || ([ref isBranch] && [[self.repository remoteRefForBranch:ref error:NULL] remoteName]))
		hasRemote = YES;

	[remoteControls setEnabled:hasRemote forSegment:kFetchSegment];
	[remoteControls setEnabled:hasRemote forSegment:kPullSegment];
	[remoteControls setEnabled:hasRemote forSegment:kPushSegment];
}

- (IBAction)fetchPullPushAction:(id)sender
{
	NSInteger selectedSegment = [sender selectedSegment];

	if (selectedSegment == kAddRemoteSegment) {
		[self tryToPerform:@selector(addRemote:) with:self];
		return;
	}

	NSInteger index = [sourceView selectedRow];
	PBSourceViewItem *item = [sourceView itemAtRow:index];
	PBGitRef *ref = [[item revSpecifier] ref];

	if (!ref && (item.parent == remotes))
		ref = [PBGitRef refFromString:[kGitXRemoteRefPrefix stringByAppendingString:[item title]]];

	if (![ref isRemote] && ![ref isBranch])
		return;

	PBGitRef *remoteRef = [self.repository remoteRefForBranch:ref error:NULL];
	if (!remoteRef)
		return;

	if (selectedSegment == kFetchSegment) {
		[self.windowController performFetchForRef:ref];
	} else if (selectedSegment == kPullSegment) {
		[self.windowController performPullForBranch:ref remote:remoteRef rebase:NO];
	} else if (selectedSegment == kPushSegment && ref.isRemote) {
		[self.windowController performPushForBranch:nil toRemote:remoteRef];
	} else if (selectedSegment == kPushSegment && ref.isBranch) {
		[self.windowController performPushForBranch:ref toRemote:remoteRef];
	}
}

@end

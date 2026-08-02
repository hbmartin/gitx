#import <Cocoa/Cocoa.h>

#import "PBViewController.h"

@class PBGitRef;
@class PBGitRepository;
@class PBGitRevSpecifier;
@class PBGitWindowController;
@class PBSourceViewGitSubmoduleItem;
@class PBSourceViewItem;

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBGitSidebarController interface.
/// App-hosted Objective-C tests use this declaration without importing the
/// complete generated header, while production owns the runtime class.
@interface PBGitSidebarController : PBViewController <NSMenuDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>

- (nullable instancetype)initWithRepository:(PBGitRepository *)repository
							superController:(nullable PBGitWindowController *)controller;

- (void)selectCurrentBranch;

- (NSMenu *)menuForRow:(NSInteger)row;
- (void)menuNeedsUpdate:(NSMenu *)menu;

- (IBAction)fetchPullPushAction:(nullable id)sender;

@property (readonly) NSMutableArray<PBSourceViewItem *> *items;
@property (nullable, readonly) PBSourceViewItem *remotes;
@property (nullable, readonly) NSOutlineView *sourceView;
@property (nullable, readonly) NSView *sourceListControlsView;

@end

/// Private Objective-C selectors exercised directly by characterization tests.
@interface PBGitSidebarController (GitXTestsCompatibility)

- (void)reloadSidebarAfterReferencesChange;
- (void)reloadSidebarPresentation;
- (void)synchronizeConfiguredRemotes;
- (void)repositorySettingsDidChange:(NSNotification *)notification;
- (nullable PBSourceViewItem *)selectedItem;
- (nullable PBSourceViewItem *)itemForRev:(PBGitRevSpecifier *)rev;
- (nullable PBSourceViewItem *)addRevSpec:(PBGitRevSpecifier *)rev;
- (void)removeRevSpec:(PBGitRevSpecifier *)rev;
- (void)openSubmoduleFromMenuItem:(NSMenuItem *)menuItem;
- (void)openSubmoduleAtURL:(NSURL *)submoduleURL;
- (void)doubleClicked:(id)sender;
- (void)toggleBranchSort:(id)sender;
- (NSArray<PBSourceViewItem *> *)visibleChildrenForItem:(PBSourceViewItem *)item;
- (void)outlineViewSelectionDidChange:(NSNotification *)notification;
- (nullable NSView *)outlineView:(NSOutlineView *)outlineView
			  viewForTableColumn:(nullable NSTableColumn *)tableColumn
							item:(PBSourceViewItem *)item;
- (nullable NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isGroupItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldShowOutlineCellForItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView
	shouldEditTableColumn:(nullable NSTableColumn *)tableColumn
					 item:(id)item;
- (nullable id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item;
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item;
- (nullable id)outlineView:(NSOutlineView *)outlineView
	objectValueForTableColumn:(nullable NSTableColumn *)tableColumn
					   byItem:(id)item;
- (void)expandCollapseItem:(NSNotification *)notification;
- (void)updateActionMenu;
- (void)updateRemoteControls;
- (void)addMenuItemsForRef:(nullable PBGitRef *)ref toMenu:(NSMenu *)menu;
- (void)addMenuItemsForSubmodule:(nullable PBSourceViewGitSubmoduleItem *)submodule toMenu:(NSMenu *)menu;

@end

NS_ASSUME_NONNULL_END

#import <Quartz/Quartz.h>

#import "PBGitHistoryController.h"
#import "PBGitTree.h"
#import "PBGitRepository.h"
#import "PBGitCommit.h"
#import "PBGitWindowController.h"
#import "PBHistorySearchController.h"
#import "PBQLTextView.h"
#import "PBDiffWindowController.h"
#import "GitXCommitCopier.h"
#import "GitX-Swift.h"

#define kHistoryDetailViewIndex 0
#define kHistoryTreeViewIndex 1

@interface PBGitHistoryController (PBFacadePrivate)
- (void)updateKeys;
- (PBGitCommit *)firstCommit;
@end

#pragma clang diagnostic push
// These selectors remain declared on the stable primary façade; this category
// only splits their source-level implementation from nib lifecycle wiring.
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation PBGitHistoryController (PBFacadeUI)

- (IBAction)openSelectedFile:(id)sender
{
	NSArray *selectedFiles = [self.treeController selectedObjects];
	if ([selectedFiles count] == 0)
		return;
	PBGitTree *tree = [selectedFiles objectAtIndex:0];
	NSString *name = [tree tmpFileNameForContents];
	[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:name]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	SEL action = menuItem.action;

	if (action == @selector(setDetailedView:)) {
		[menuItem setState:(self.selectedCommitDetailsIndex == kHistoryDetailViewIndex) ? NSControlStateValueOn : NSControlStateValueOff];
	} else if (action == @selector(setTreeView:)) {
		[menuItem setState:(self.selectedCommitDetailsIndex == kHistoryTreeViewIndex) ? NSControlStateValueOn : NSControlStateValueOff];
	}

	if ([self respondsToSelector:action]) {
		if (action == @selector(createBranch:) || action == @selector(createTag:)) {
			return self.singleCommitSelected;
		}

		return YES;
	}

	if (action == @selector(copy:) || action == @selector(copySHA:) || action == @selector(copyShortName:) || action == @selector(copyPatch:)) {
		return self.commitController.selectedObjects.count > 0;
	}

	return [[self nextResponder] validateMenuItem:menuItem];
}

- (void)setHistorySearch:(NSString *)searchString mode:(PBHistorySearchMode)mode
{
	[self.searchController setHistorySearch:searchString mode:mode];
}

- (IBAction)selectNext:(id)sender
{
	NSResponder *firstResponder = [[[self view] window] firstResponder];
	if ([firstResponder isKindOfClass:[PBQLTextView class]]) {
		[(PBQLTextView *)firstResponder performFindPanelAction:sender];
		return;
	}

	[self.searchController selectNextResult];
}
- (IBAction)selectPrevious:(id)sender
{
	NSResponder *firstResponder = [[[self view] window] firstResponder];
	if ([firstResponder isKindOfClass:[PBQLTextView class]]) {
		[(PBQLTextView *)firstResponder performFindPanelAction:sender];
		return;
	}

	[self.searchController selectPreviousResult];
}

- (IBAction)selectParentCommit:(id)sender
{
	NSArray *selectedObjects = self.commitController.selectedObjects;
	if (selectedObjects.count != 1) return;

	PBGitCommit *selectedCommit = selectedObjects[0];

	NSArray<GTOID *> *parents = selectedCommit.parents;
	if (parents.count == 0) return;
	/* TODO: This is a merge commit. It would be nice to choose the parent with
	 * the most commits, but for now we will use whatever commit is our first parent.
	 */

	[self selectCommit:parents[0]];
}

- (IBAction)copy:(id)sender
{
	[GitXCommitCopier putStringToPasteboard:[GitXCommitCopier toSHAAndHeadingString:self.commitController.selectedObjects]];
}

- (IBAction)copySHA:(id)sender
{
	[GitXCommitCopier putStringToPasteboard:[GitXCommitCopier toFullSHA:self.commitController.selectedObjects]];
}

- (IBAction)copyShortName:(id)sender
{
	[GitXCommitCopier putStringToPasteboard:[GitXCommitCopier toShortName:self.commitController.selectedObjects]];
}

- (IBAction)copyPatch:(id)sender
{
	[GitXCommitCopier putStringToPasteboard:[GitXCommitCopier toPatch:self.commitController.selectedObjects]];
}

- (IBAction)toggleQLPreviewPanel:(id)sender
{
	if ([QLPreviewPanel sharedPreviewPanelExists] && [[QLPreviewPanel sharedPreviewPanel] isVisible])
		[[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
	else
		[[QLPreviewPanel sharedPreviewPanel] makeKeyAndOrderFront:nil];
}

- (void)updateQuicklookForce:(BOOL)force
{
	if (!force && (![QLPreviewPanel sharedPreviewPanelExists] || ![[QLPreviewPanel sharedPreviewPanel] isVisible]))
		return;

	[[QLPreviewPanel sharedPreviewPanel] reloadData];
}

- (IBAction)refresh:(id)sender
{
	[self.repository forceUpdateRevisions];
}

- (void)updateView
{
	[self updateKeys];
}

- (NSResponder *)firstResponder;
{
	return self.commitList;
}

- (BOOL)hasNonlinearPath
{
	return self.commitController.filterPredicate || self.commitController.sortDescriptors.count > 0;
}

- (NSMenu *)tableColumnMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
	for (NSTableColumn *column in self.commitList.tableColumns) {
		NSMenuItem *item = [[NSMenuItem alloc] init];
		[item setTitle:[[column headerCell] stringValue]];
		[item bind:@"value"
			   toObject:column
			withKeyPath:@"hidden"
				options:[NSDictionary dictionaryWithObject:@"NSNegateBoolean" forKey:NSValueTransformerNameBindingOption]];
		[menu addItem:item];
	}
	return menu;
}

#pragma mark Tree Context Menu Methods

- (void)showCommitsFromTree:(id)sender
{
	NSString *searchString = [(NSArray *)[sender representedObject] componentsJoinedByString:@" "];
	[self setHistorySearch:searchString mode:PBHistorySearchModePath];
}

- (void)checkoutFiles:(id)sender
{
	NSMutableArray *files = [NSMutableArray array];
	for (NSString *filePath in [sender representedObject])
		[files addObject:[filePath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];

	NSError *error = nil;
	BOOL success = [self.repository checkoutFiles:files fromRefish:self.selectedCommits.firstObject error:&error];
	if (!success) {
		[self.windowController showErrorSheet:error];
	}
}

- (void)diffFilesAction:(id)sender
{
	/* TODO: Move that to the document */
	[PBDiffWindowController showDiffWindowWithFiles:[sender representedObject] fromCommit:self.selectedCommits.firstObject diffCommit:nil];
}

#pragma mark -
#pragma mark File browser

- (NSMenu *)contextMenuForTreeView
{
	NSArray *filePaths = [[self.treeController selectedObjects] valueForKey:@"fullPath"];

	NSMenu *menu = [[NSMenu alloc] init];
	for (NSMenuItem *item in [self menuItemsForPaths:filePaths])
		[menu addItem:item];
	return menu;
}

- (NSArray *)menuItemsForPaths:(NSArray *)paths
{
	PBHistoryMenuBuilder *builder = [self valueForKey:@"menuBuilder"];
	return [builder menuItemsForPaths:paths selectedCommit:self.selectedCommits.firstObject];
}

#pragma mark -
#pragma mark Quick Look

#pragma mark <QLPreviewPanelDataSource>

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(id)panel
{
	return [[(NSOutlineView *)[self valueForKey:@"fileBrowser"] selectedRowIndexes] count];
}

- (id<QLPreviewItem>)previewPanel:(id)panel previewItemAtIndex:(NSInteger)index
{
	PBGitTree *treeItem = (PBGitTree *)[[self.treeController selectedObjects] objectAtIndex:index];
	NSURL *previewURL = [NSURL fileURLWithPath:[treeItem tmpFileNameForContents]];

	return (id<QLPreviewItem>)previewURL;
}

#pragma mark <QLPreviewPanelDelegate>


- (BOOL)previewPanel:(id)panel handleEvent:(NSEvent *)event
{
	NSOutlineView *browser = [self valueForKey:@"fileBrowser"];
	// redirect all key down events to the table view
	if ([event type] == NSEventTypeKeyDown) {
		[browser keyDown:event];
		return YES;
	}
	return NO;
}

// This delegate method provides the rect on screen from which the panel will zoom.
- (NSRect)previewPanel:(id)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item
{
	NSOutlineView *browser = [self valueForKey:@"fileBrowser"];
	NSInteger index = [browser rowForItem:[[self.treeController selectedNodes] objectAtIndex:0]];
	if (index == NSNotFound) {
		return NSZeroRect;
	}

	NSRect iconRect = [browser frameOfCellAtColumn:0 row:index];

	// check that the icon rect is visible on screen
	NSRect visibleRect = [browser visibleRect];

	if (!NSIntersectsRect(visibleRect, iconRect)) {
		return NSZeroRect;
	}

	// convert icon rect to screen coordinates
	iconRect = [browser.window.contentView convertRect:iconRect fromView:browser];
	iconRect = [browser.window convertRectToScreen:iconRect];

	return iconRect;
}

@end


@implementation PBGitHistoryController (PBContextMenu)

- (NSArray<NSMenuItem *> *)menuItemsForRef:(PBGitRef *)ref
{
	PBHistoryMenuBuilder *builder = [self valueForKey:@"menuBuilder"];
	return [builder menuItemsForRef:ref];
}

- (NSArray<NSMenuItem *> *)menuItemsForCommits:(NSArray<PBGitCommit *> *)commits
{
	PBHistoryMenuBuilder *builder = [self valueForKey:@"menuBuilder"];
	return [builder menuItemsForCommits:commits];
}

@end
#pragma clang diagnostic pop

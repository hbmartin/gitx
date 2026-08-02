//
//  PBGitHistoryView.h
//  GitX
//
//  Created by Pieter de Bie on 19-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBViewController.h"
#import "PBHistorySearchMode.h"

@class PBGitCommit;
@class PBGitTree;

@class PBGitSidebarController;
@class PBWebHistoryController;
@class PBGitGradientBarView;
@class PBCommitList;
@class GLFileView;
@class GTOID;
@class PBHistorySearchController;
@class PBGitRef;

NS_ASSUME_NONNULL_BEGIN

@interface PBGitHistoryController : PBViewController <NSMenuItemValidation>

@property (readonly) NSArrayController *commitController;
@property (readonly) NSTreeController *treeController;
@property (readonly) PBHistorySearchController *searchController;

@property (assign) NSInteger selectedCommitDetailsIndex;
@property (nullable) PBGitTree *gitTree;
@property NSArray<PBGitCommit *> *webCommits;
@property NSArray<PBGitCommit *> *selectedCommits;

@property (readonly) PBCommitList *commitList;
@property (readonly) BOOL singleCommitSelected;
@property (readonly) BOOL singleNonHeadCommitSelected;

/// YES when the pinned Uncommitted Changes row is the current selection.
@property (readonly) BOOL uncommittedChangesSelected;

/// Selects the pinned Uncommitted Changes row, refreshing the index first if
/// the row does not exist yet. On a clean repository this degrades to plain
/// History.
- (void)selectUncommittedChanges;

- (BOOL)hasNonlinearPath;
- (NSMenu *)tableColumnMenu;
- (void)selectCommit:(nullable GTOID *)commit;
- (void)updateQuicklookForce:(BOOL)force;

- (void)setHistorySearch:(NSString *)searchString mode:(PBHistorySearchMode)mode;

// Context menu methods
- (NSMenu *)contextMenuForTreeView;
- (NSArray<NSMenuItem *> *)menuItemsForPaths:(NSArray<NSString *> *)paths;
- (void)showCommitsFromTree:(id)sender;

- (IBAction)setDetailedView:(id)sender;
- (IBAction)setTreeView:(id)sender;
- (IBAction)setBranchFilter:(id)sender;

- (IBAction)refresh:(nullable id)sender;
- (IBAction)toggleQLPreviewPanel:(id)sender;
- (IBAction)openSelectedFile:(id)sender;

// Find/Search methods
- (IBAction)selectNext:(id)sender;
- (IBAction)selectPrevious:(id)sender;
- (IBAction)selectParentCommit:(id)sender;

- (IBAction)copy:(id)sender;
- (IBAction)copySHA:(id)sender;
- (IBAction)copyShortName:(id)sender;
- (IBAction)copyPatch:(id)sender;
- (IBAction)createPatch:(id)sender;

@end

@interface PBGitHistoryController (PBContextMenu)

- (nullable NSArray<NSMenuItem *> *)menuItemsForRef:(nullable PBGitRef *)ref;
- (NSArray<NSMenuItem *> *)menuItemsForCommits:(NSArray<PBGitCommit *> *)commits;

@end

NS_ASSUME_NONNULL_END

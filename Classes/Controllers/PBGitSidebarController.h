//
//  PBGitSidebar.h
//  GitX
//
//  Created by Pieter de Bie on 9/8/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBViewController.h"
#import "PBHistorySearchMode.h"

@class PBSourceViewItem;
@class PBGitHistoryController;

NS_ASSUME_NONNULL_BEGIN

@interface PBGitSidebarController : PBViewController <NSMenuDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>

- (void)selectCurrentBranch;

- (NSMenu *)menuForRow:(NSInteger)row;
- (void)menuNeedsUpdate:(NSMenu *)menu;

- (IBAction)fetchPullPushAction:(nullable id)sender;

@property (readonly) NSMutableArray<PBSourceViewItem *> *items;
@property (nullable, readonly) PBSourceViewItem *remotes;
@property (nullable, readonly) NSOutlineView *sourceView;
@property (nullable, readonly) NSView *sourceListControlsView;

@end

NS_ASSUME_NONNULL_END

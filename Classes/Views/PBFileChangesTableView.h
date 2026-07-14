//
//  PBFileChangesTableView.h
//  GitX
//
//  Created by Pieter de Bie on 09-10-08.
//  Copyright 2008 Pieter de Bie. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class PBFileChangesTableView;

@protocol PBFileChangesTableViewStagingDelegate <NSObject>
- (void)fileChangesTableViewDidRequestStagingToggle:(PBFileChangesTableView *)tableView;
@end

@interface PBFileChangesTableView : NSTableView
@end

NS_ASSUME_NONNULL_END

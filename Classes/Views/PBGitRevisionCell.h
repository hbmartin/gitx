//
//  PBGitRevisionCell.h
//  GitX
//
//  Created by Pieter de Bie on 17-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBGitGrapher.h"
#import "PBGraphCellInfo.h"
#import "PBGitHistoryController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBGitRevisionCell : NSTableCellView {
	PBGitCommit *_Nullable objectValue;
	PBGraphCellInfo *_Nullable cellInfo;
	__weak IBOutlet PBGitHistoryController *_Nullable controller;
}

- (int)indexAtX:(CGFloat)x;
- (NSRect)rectAtIndex:(int)index;
- (void)drawLabelAtIndex:(int)index inRect:(NSRect)rect;

@property (strong, nullable) PBGitCommit *objectValue;

@end

NS_ASSUME_NONNULL_END

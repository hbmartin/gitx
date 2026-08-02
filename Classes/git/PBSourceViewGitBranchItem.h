//
//  PBSourceViewGitBranchItem.h
//  GitX
//
//  Created by Nathan Kinsinger on 3/2/10.
//  Copyright 2010 Nathan Kinsinger. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBSourceViewItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBSourceViewGitBranchItem : PBSourceViewItem

+ (instancetype)branchItemWithRevSpec:(PBGitRevSpecifier *)revSpecifier;

@end

NS_ASSUME_NONNULL_END

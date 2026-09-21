//
//  PBSourceViewBadge.h
//  GitX
//
//  Created by Nathan Kinsinger on 2/13/10.
//  Copyright 2010 Nathan Kinsinger. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBSourceViewBadge : NSObject {
}

+ (NSImage *)checkedOutBadgeForCell:(NSTableCellView *)cell;
+ (NSImage *)numericBadge:(NSInteger)number forCell:(NSTableCellView *)cell;

@end

NS_ASSUME_NONNULL_END

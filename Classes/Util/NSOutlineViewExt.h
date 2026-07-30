//
//  NSOutlineViewExit.h
//  GitX
//
//  Created by Pieter de Bie on 9/9/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSOutlineView (PBExpandParents)

- (void)PBExpandItem:(nullable id)item expandParents:(BOOL)expand;
@end

NS_ASSUME_NONNULL_END

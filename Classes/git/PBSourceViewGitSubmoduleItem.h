//
//  PBSourceViewGitSubmoduleItem.h
//  GitX
//
//  Created by Seth Raphael on 9/14/12.
//
//

#import <Foundation/Foundation.h>
#import "PBSourceViewItem.h"

@class GTSubmodule;

NS_ASSUME_NONNULL_BEGIN

@interface PBSourceViewGitSubmoduleItem : PBSourceViewItem

+ (instancetype)itemWithSubmodule:(GTSubmodule *)submodule;

@property (nonatomic, readonly) GTSubmodule *submodule;
@property (nonatomic, readonly) NSURL *path;

@end

NS_ASSUME_NONNULL_END

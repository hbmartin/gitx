//
//  PBRemoteProgressSheetController.h
//  GitX
//
//  Created by Nathan Kinsinger on 12/6/09.
//  Copyright 2009 Nathan Kinsinger. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "RJModalRepoSheet.h"

NS_ASSUME_NONNULL_BEGIN

@class PBGitWindowController;

typedef NSError *_Nullable(NS_SWIFT_SENDABLE ^ PBProgressSheetExecutionHandler)(void);

@interface PBRemoteProgressSheet : RJModalRepoSheet

+ (instancetype)progressSheetWithTitle:(NSString *)title description:(NSString *)description windowController:(PBGitWindowController *)windowController;
+ (instancetype)progressSheetWithTitle:(NSString *)title description:(NSString *)description;

- (void)beginProgressSheetForBlock:(PBProgressSheetExecutionHandler)executionBlock
				 completionHandler:(void (^)(NSError *_Nullable))completionHandler
	NS_SWIFT_NAME(begin(execution:completion:));

@end

NS_ASSUME_NONNULL_END

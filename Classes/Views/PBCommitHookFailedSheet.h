//
//  PBCommitHookFailedSheet.h
//  GitX
//
//  Created by Sebastian Staudt on 9/12/10.
//  Copyright 2010 Sebastian Staudt. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "PBGitXMessageSheet.h"

@class PBGitWindowController;

NS_ASSUME_NONNULL_BEGIN

@interface PBCommitHookFailedSheet : PBGitXMessageSheet

+ (void)beginWithMessageText:(NSString *)message
					infoText:(NSString *)info
			windowController:(PBGitWindowController *)windowController
		   completionHandler:(RJSheetCompletionHandler)handler;

- (IBAction)forceCommit:(id)sender;

@end

NS_ASSUME_NONNULL_END

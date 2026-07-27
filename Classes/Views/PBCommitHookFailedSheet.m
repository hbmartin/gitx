//
//  PBCommitHookFailedSheet.m
//  GitX
//
//  Created by Sebastian Staudt on 9/12/10.
//  Copyright 2010 Sebastian Staudt. All rights reserved.
//

#import "PBCommitHookFailedSheet.h"
#import "PBGitWindowController.h"


@implementation PBCommitHookFailedSheet

#pragma mark -
#pragma mark PBCommitHookFailedSheet

+ (void)beginWithMessageText:(NSString *)message
					infoText:(NSString *)info
			windowController:(PBGitWindowController *)windowController
		   completionHandler:(RJSheetCompletionHandler)handler
{
	PBCommitHookFailedSheet *sheet = [[self alloc] initWithWindowNibName:@"PBCommitHookFailedSheet"
														windowController:windowController];
	[sheet beginMessageSheetWithMessageText:message
								   infoText:info
						  completionHandler:handler];
}

- (IBAction)forceCommit:(id)sender
{
	[self acceptSheet:sender];
}

- (IBAction)closeMessageSheet:(id)sender
{
	[self cancelSheet:sender];
}

@end

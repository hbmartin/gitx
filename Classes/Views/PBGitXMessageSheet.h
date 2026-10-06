//
//  PBGitXMessageSheet.h
//  GitX
//
//  Created by BrotherBard on 7/4/10.
//  Copyright 2010 BrotherBard. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "RJModalRepoSheet.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBGitXMessageSheet : RJModalRepoSheet {
	NSImageView *iconView;
	NSTextField *messageField;
	NSTextView *infoView;
	NSScrollView *scrollView;
}

+ (void)beginSheetWithMessage:(NSString *)message
						 info:(NSString *)info
			 windowController:(PBGitWindowController *)windowController;

+ (void)beginSheetWithError:(NSError *)error
		   windowController:(PBGitWindowController *)windowController;

+ (void)beginSheetWithMessage:(NSString *)message
						 info:(NSString *)info
			 windowController:(PBGitWindowController *)windowController
			completionHandler:(nullable RJSheetCompletionHandler)handler;

+ (void)beginSheetWithError:(NSError *)error
		   windowController:(PBGitWindowController *)windowController
		  completionHandler:(nullable RJSheetCompletionHandler)handler;

- (void)beginMessageSheetWithMessageText:(NSString *)message
								infoText:(NSString *)info
					   completionHandler:(nullable RJSheetCompletionHandler)handler;

- (IBAction)closeMessageSheet:(nullable id)sender;


@property (nullable, strong) IBOutlet NSImageView *iconView;
@property (nullable, strong) IBOutlet NSTextField *messageField;
@property (nullable, strong) IBOutlet NSTextView *infoView;
@property (nullable, strong) IBOutlet NSScrollView *scrollView;

@end

NS_ASSUME_NONNULL_END

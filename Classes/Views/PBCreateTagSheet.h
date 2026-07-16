//
//  PBCreateTagSheet.h
//  GitX
//
//  Created by Nathan Kinsinger on 12/18/09.
//  Copyright 2009 Nathan Kinsinger. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "PBGitRefish.h"
#import "RJModalRepoSheet.h"

@class PBGitRepository;

NS_ASSUME_NONNULL_BEGIN

@interface PBCreateTagSheet : RJModalRepoSheet

+ (void)beginSheetWithRefish:(id<PBGitRefish>)refish
			windowController:(PBGitWindowController *)windowController
		   completionHandler:(nullable RJSheetCompletionHandler)handler
	NS_SWIFT_NAME(begin(refish:windowController:completionHandler:));

- (IBAction)createTag:(nullable id)sender;
- (IBAction)closeCreateTagSheet:(nullable id)sender;

@property (nonatomic, strong) id<PBGitRefish> targetRefish;

@property (nullable, nonatomic, weak) IBOutlet NSTextField *tagNameField;
@property (nullable, nonatomic, strong) IBOutlet NSTextView *tagMessageText;
@property (nullable, nonatomic, weak) IBOutlet NSTextField *errorMessageField;

@end


NS_ASSUME_NONNULL_END

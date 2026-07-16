//
//  PBAddRemoteSheet.h
//  GitX
//
//  Created by Nathan Kinsinger on 12/8/09.
//  Copyright 2009 Nathan Kinsinger. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "RJModalRepoSheet.h"

@class PBGitWindowController;

NS_ASSUME_NONNULL_BEGIN

@interface PBAddRemoteSheet : RJModalRepoSheet

+ (void)beginSheetWithWindowController:(PBGitWindowController *)windowController
					 completionHandler:(nullable RJSheetCompletionHandler)handler
	NS_SWIFT_NAME(begin(windowController:completionHandler:));

- (IBAction)browseFolders:(nullable id)sender;
- (IBAction)addRemote:(nullable id)sender;
- (IBAction)showHideHiddenFiles:(nullable id)sender;
- (IBAction)cancelOperation:(nullable id)sender;

@property (nullable, readwrite, weak) IBOutlet NSTextField *remoteName;
@property (nullable, readwrite, weak) IBOutlet NSTextField *remoteURL;
@property (nullable, readwrite, weak) IBOutlet NSTextField *errorMessage;

@property (nullable, readwrite, strong) NSOpenPanel *browseSheet;
@property (nullable, readwrite, strong) IBOutlet NSView *browseAccessoryView;

@end

NS_ASSUME_NONNULL_END

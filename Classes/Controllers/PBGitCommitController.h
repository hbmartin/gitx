//
//  PBGitCommitController.h
//  GitX
//
//  Created by Pieter de Bie on 19-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBViewController.h"

@class PBGitIndex;

NS_ASSUME_NONNULL_BEGIN

@interface PBGitCommitController : PBViewController <NSMenuItemValidation>

- (IBAction)refresh:(nullable id)sender;
- (IBAction)prepareCommitMessage:(nullable id)sender;
- (IBAction)commit:(nullable id)sender;
- (IBAction)forceCommit:(nullable id)sender;
- (IBAction)signOff:(nullable id)sender;

- (PBGitIndex *)index;

@end

NS_ASSUME_NONNULL_END

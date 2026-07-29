//
//  PBViewController.h
//  GitX
//
//  Created by Pieter de Bie on 22-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "PBGitRepository.h"

@class PBGitWindowController;

NS_ASSUME_NONNULL_BEGIN

@interface PBViewController : NSViewController

@property (nonatomic, weak, readonly, nullable) PBGitRepository *repository;
@property (weak, readonly, nullable) PBGitWindowController *windowController;
@property (copy, nullable) NSString *status;
@property (assign) BOOL isBusy;

- (nullable instancetype)initWithRepository:(PBGitRepository *)theRepository superController:(nullable PBGitWindowController *)controller;

/* closeView is called when the repository window will be closed */
- (void)closeView;

/* updateView is called once, the first time the controller's view is mounted into the repository window; warm switches remount the view without calling it again */
- (void)updateView;

- (nullable NSResponder *)firstResponder;
- (IBAction)refresh:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END

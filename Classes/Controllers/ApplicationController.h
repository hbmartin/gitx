//
//  GitTest_AppDelegate.h
//  GitTest
//
//  Created by Pieter de Bie on 13-06-08.
//  Copyright __MyCompanyName__ 2008 . All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBGitRepository.h"

NS_ASSUME_NONNULL_BEGIN

@class PBCloneRepositoryPanel;

@interface ApplicationController : NSObject <NSApplicationDelegate> {
	IBOutlet NSWindow *_Nullable window;
	IBOutlet id _Nullable firstResponder;

	PBCloneRepositoryPanel *_Nullable cloneRepositoryPanel;
	bool started;
}

- (IBAction)openPreferencesWindow:(nullable id)sender;
- (IBAction)showAboutPanel:(nullable id)sender;

- (IBAction)installCliTool:(nullable id)sender;

- (IBAction)showHelp:(nullable id)sender;
- (IBAction)showChangeLog:(nullable id)sender;
- (IBAction)reportAProblem:(nullable id)sender;

- (IBAction)showCloneRepository:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END

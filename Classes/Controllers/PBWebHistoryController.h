//
//  PBWebGitController.h
//  GitTest
//
//  Created by Pieter de Bie on 14-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBWebController.h"

#import "PBGitCommit.h"
#import "PBGitHistoryController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBWebHistoryController : PBWebController {
	__weak IBOutlet PBGitHistoryController *_Nullable historyController;

	NSString *_Nullable diff;
}

- (void)sendKey:(NSString *)key;
- (void)scrollPageUp;
- (void)scrollPageDown;
- (void)refreshDisplayedContent;

@property (readonly, nullable) NSString *diff;

@end

NS_ASSUME_NONNULL_END

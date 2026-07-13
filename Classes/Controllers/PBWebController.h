//
//  PBWebController.h
//  GitX
//
//  Created by Pieter de Bie on 08-10-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class PBNativeContentView;

@interface PBWebController : NSObject {
	NSString *startFile;
	BOOL finishedLoading;

	// For the repository access
	__weak IBOutlet id repository;
}

@property (weak) IBOutlet NSView *view;
@property (nonatomic, readonly) PBNativeContentView *nativeView;
@property NSString *startFile;
@property (weak) id repository;

- (void)closeView;
- (void)didLoad;
- (void)preferencesChanged;
- (void)makeWebViewFirstResponder;
@end

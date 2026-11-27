//
//  PBHistorySearchController.h
//  GitX
//
//  Created by Nathan Kinsinger on 8/21/10.
//  Copyright 2010 Nathan Kinsinger. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBHistorySearchMode.h"

NS_ASSUME_NONNULL_BEGIN

@class PBGitHistoryController;
@class PBTask;

@interface PBHistorySearchController : NSObject {
	PBHistorySearchMode searchMode;
	NSIndexSet *_Nullable results;
	NSTimer *_Nullable searchTimer;
	PBTask *_Nullable backgroundSearchTask;
	NSPanel *_Nullable rewindPanel;
}

@property (weak, nullable) IBOutlet PBGitHistoryController *historyController;
@property (weak, nullable) IBOutlet NSArrayController *commitController;

@property (weak, nullable) IBOutlet NSSearchField *searchField;
@property (weak, nullable) IBOutlet NSSegmentedControl *stepper;
@property (weak, nullable) IBOutlet NSTextField *numberOfMatchesField;
@property (weak, nullable) IBOutlet NSProgressIndicator *progressIndicator;

@property PBHistorySearchMode searchMode;


- (BOOL)isRowInSearchResults:(NSInteger)rowIndex;
- (BOOL)hasSearchResults;

- (void)selectSearchMode:(id)sender;

- (void)selectNextResult;
- (void)selectPreviousResult;
- (IBAction)stepperPressed:(id)sender;

- (void)clearSearch;
- (IBAction)updateSearch:(nullable id)sender;

/// Ignores a nil or empty search string; otherwise selects the mode and submits the text.
- (void)setHistorySearch:(nullable NSString *)searchString mode:(PBHistorySearchMode)mode;

@end

NS_ASSUME_NONNULL_END

#import <Cocoa/Cocoa.h>

#import "PBHistorySearchMode.h"

@class PBGitHistoryController;

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBHistorySearchController interface.
/// App-hosted tests use this declaration without importing the complete generated
/// header, while production owns the runtime class.
@interface PBHistorySearchController : NSObject

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

- (void)setHistorySearch:(nullable NSString *)searchString mode:(PBHistorySearchMode)mode;

@end

NS_ASSUME_NONNULL_END

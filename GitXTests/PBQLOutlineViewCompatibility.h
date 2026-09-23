#import <AppKit/AppKit.h>

@class PBGitHistoryController;

NS_ASSUME_NONNULL_BEGIN

@interface PBQLOutlineView : NSOutlineView <NSOutlineViewDataSource, NSFilePromiseProviderDelegate>

@property (nullable, nonatomic, weak) IBOutlet PBGitHistoryController *controller;

@end

NS_ASSUME_NONNULL_END

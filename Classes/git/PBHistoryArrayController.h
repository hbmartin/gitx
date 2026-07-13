#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps the mutable Working State row pinned above the arranged commit list.
@interface PBHistoryArrayController : NSArrayController
@property (nonatomic, nullable) id pinnedObject;
@end

NS_ASSUME_NONNULL_END

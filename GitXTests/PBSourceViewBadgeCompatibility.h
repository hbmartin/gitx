#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBSourceViewBadge interface.
/// App-hosted Objective-C tests cannot directly import the app target's generated header.
@interface PBSourceViewBadge : NSObject

+ (NSColor *)badgeHighlightColor;
+ (NSColor *)badgeBackgroundColor;
+ (NSColor *)badgeColorForCell:(NSTableCellView *)cell;
+ (NSColor *)badgeTextColorForCell:(NSTableCellView *)cell;
+ (NSImage *)badge:(NSString *)badge forCell:(NSTableCellView *)cell;
+ (NSImage *)checkedOutBadgeForCell:(NSTableCellView *)cell;
+ (NSImage *)numericBadge:(NSInteger)number forCell:(NSTableCellView *)cell;

@end

NS_ASSUME_NONNULL_END

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift facade around HighlightKit used by the Objective-C native viewers.
@interface PBHighlighting : NSObject
+ (NSAttributedString *)highlightedStringForText:(NSString *)text path:(NSString *)path;
+ (nullable NSString *)languageNameForPath:(NSString *)path;
+ (BOOL)shouldHighlightDiffWithByteCount:(NSUInteger)byteCount;
@end

NS_ASSUME_NONNULL_END

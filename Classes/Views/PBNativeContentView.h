#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const PBNativeSectionTitleKey;
extern NSString *const PBNativeSectionTextKey;
extern NSString *const PBNativeSectionPathKey;
extern NSString *const PBNativeSectionContextKey;
extern NSString *const PBNativeSectionEntriesKey;
extern NSString *const PBNativeSectionImageSourceKey;
extern NSString *const PBNativeSectionDiffLayoutKey;
extern NSString *const PBNativeSectionSuppressionPatternsKey;
extern NSString *const PBNativeImageSourceRevisionsKey;
extern NSString *const PBNativeImageSourceWorkingTreeKey;
extern NSString *const PBNativeImageSourceWorkingTreeURLKey;
extern NSString *const PBNativeImageSourceGitLaunchPathKey;
extern NSString *const PBNativeImageSourceGitDirectoryKey;
extern NSString *const PBNativeImageSourceTaskDirectoryKey;

@class PBNativeContentView;

@protocol PBNativeContentViewDelegate <NSObject>
@optional
- (void)nativeContentView:(PBNativeContentView *)view performDiffAction:(NSString *)action patch:(NSString *)patch;
- (void)nativeContentView:(PBNativeContentView *)view selectCommit:(NSString *)sha;
- (nullable NSData *)nativeContentView:(PBNativeContentView *)view
					  imageDataForPath:(NSString *)path
							   section:(NSUInteger)sectionIndex
						   imageSource:(NSDictionary<NSString *, id> *)imageSource;
@end

/// Shared, selectable AppKit renderer for source, blame, history, and diff content.
@interface PBNativeContentView : NSView <NSTextViewDelegate>

@property (nonatomic, weak, nullable) id<PBNativeContentViewDelegate> delegate;
@property (nonatomic, readonly) NSTextView *textView;

- (void)setAccessoryView:(nullable NSView *)accessoryView;
- (void)showMessage:(NSString *)message;
- (void)showSourceSections:(NSArray<NSDictionary *> *)sections;
- (void)showBlameSections:(NSArray<NSDictionary *> *)sections;
- (void)showHistorySections:(NSArray<NSDictionary *> *)sections;
- (void)showDiffSections:(NSArray<NSDictionary *> *)sections;
- (void)scrollPageUp;
- (void)scrollPageDown;

@end

NS_ASSUME_NONNULL_END

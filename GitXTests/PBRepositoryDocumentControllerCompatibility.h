#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBRepositoryDocumentController interface.
/// App-hosted Objective-C tests cannot directly import the app target's generated header.
@interface PBRepositoryDocumentController : NSDocumentController

+ (NSOpenPanel *)newOpenPanel;
- (void)beginOpenPanel:(NSOpenPanel *)openPanel
              forTypes:(nullable NSArray<NSString *> *)types
     completionHandler:(void (^)(NSInteger response))completionHandler;
- (nullable NSDocument *)makeUntitledDocumentOfType:(NSString *)typeName
                                               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;

@end

NS_ASSUME_NONNULL_END

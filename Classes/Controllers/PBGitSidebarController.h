//
//  PBGitSidebarController.h
//  GitX
//
//  Objective-C compatibility surface for the Swift sidebar controller.
//

#import "GitX-Swift.h"

@class PBSourceViewItem;

NS_ASSUME_NONNULL_BEGIN

@interface PBGitSidebarController (GitXTypedItems)

@property (readonly) NSMutableArray<PBSourceViewItem *> *items;

@end

NS_ASSUME_NONNULL_END

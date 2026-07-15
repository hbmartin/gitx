#import "GitXRelativeDateFormatter.h"
#import "PBRepositoryFinder.h"
#import "PBGitRevSpecifier.h"
#import "PBGitDefaults.h"
#import "PBHighlighting.h"
#import "PBNativeContentView.h"
#import "PBTask.h"
#import "PBProcessEnvironment.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBReferenceActionPolicy : NSObject
+ (BOOL)canPushRefishTypeToNamedRemote:(nullable NSString *)refishType
    NS_SWIFT_NAME(canPush(refishType:));
+ (BOOL)canDeleteRefishType:(nullable NSString *)refishType
    NS_SWIFT_NAME(canDelete(refishType:));
+ (NSString *)deletionMenuTitleForRefName:(NSString *)refName
                                 isRemote:(BOOL)isRemote
    NS_SWIFT_NAME(deletionMenuTitle(refName:isRemote:));
+ (NSString *)deletionConfirmationTitleForRefishType:(NSString *)refishType
                                            shortName:(NSString *)shortName
    NS_SWIFT_NAME(deletionConfirmationTitle(refishType:shortName:));
+ (NSString *)deletionConfirmationMessageForRefishType:(NSString *)refishType
                                              shortName:(NSString *)shortName
    NS_SWIFT_NAME(deletionConfirmationMessage(refishType:shortName:));
+ (NSString *)deletionConfirmationButtonTitleForRefishType:(NSString *)refishType
    NS_SWIFT_NAME(deletionConfirmationButtonTitle(refishType:));
@end

@interface PBRemoteSidebarSyncPlan : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *namesToAdd;
@property (nonatomic, copy, readonly) NSArray<NSString *> *namesToRemove;
+ (instancetype)planWithConfiguredRemoteNames:(NSArray<NSString *> *)configuredRemoteNames
                           existingRemoteNames:(NSArray<NSString *> *)existingRemoteNames
                           nonEmptyRemoteNames:(NSArray<NSString *> *)nonEmptyRemoteNames
    NS_SWIFT_NAME(plan(configuredRemoteNames:existingRemoteNames:nonEmptyRemoteNames:));
@end

@interface PBCommitRenderInput : NSObject
@property (nonatomic, copy, readonly) NSString *sha;
@property (nonatomic, copy, readonly, nullable) NSString *parentSHA;
@property (nonatomic, copy, readonly) NSString *shortName;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSArray<NSString *> *imageRevisions;
- (instancetype)initWithSHA:(NSString *)sha
                  parentSHA:(nullable NSString *)parentSHA
                  shortName:(NSString *)shortName
                    subject:(NSString *)subject
                     author:(NSString *)author
                 authorDate:(NSString *)authorDate;
@end

@interface PBWorkingStateRefreshPolicy : NSObject
+ (BOOL)shouldReplaceDisplayedDiff:(nullable NSString *)displayedDiff
                      renderedDiff:(NSString *)renderedDiff;
@end

@interface PBRewindOverlayView : NSView
- (instancetype)initWithFrame:(NSRect)frameRect;
@end

NS_ASSUME_NONNULL_END

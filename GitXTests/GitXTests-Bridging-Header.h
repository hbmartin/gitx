#import "GitXRelativeDateFormatter.h"
#import "PBRepositoryFinder.h"
#import "PBGitRevSpecifier.h"
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

NS_ASSUME_NONNULL_END

#import "PBGitWindowController.h"

#import "PBCommitHookFailedSheet.h"
#import "PBError.h"
#import "PBGitCommitController.h"
#import "PBGitDefaults.h"
#import "PBGitRepository.h"
#import "PBGitXMessageSheet.h"
#import "GitX-Swift.h"

#pragma clang diagnostic push
// These methods remain declared on the stable primary interface.
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation PBGitWindowController (PBDialog)

- (IBAction)showRepositorySettings:(id)sender
{
	[PBRepositorySettingsController beginSheetForRepository:self.repository windowController:self];
}

- (void)showCommitHookFailedSheet:(NSString *)messageText infoText:(NSString *)infoText commitController:(PBGitCommitController *)controller
{
	[PBCommitHookFailedSheet beginWithMessageText:messageText
										 infoText:infoText
								 commitController:controller
								completionHandler:^(__unused id sheet, NSModalResponse response) {
									if (response == NSModalResponseOK) [self.commitViewController forceCommit:self];
								}];
}

- (void)showMessageSheet:(NSString *)messageText infoText:(NSString *)infoText
{
	[PBGitXMessageSheet beginSheetWithMessage:messageText info:infoText windowController:self];
}

- (void)showErrorSheet:(NSError *)error
{
	if ([error.domain isEqualToString:PBGitXErrorDomain]) {
		[PBGitXMessageSheet beginSheetWithError:error windowController:self];
	} else {
		[[NSAlert alertWithError:error] beginSheetModalForWindow:self.window
											   completionHandler:^(__unused NSModalResponse response){
											   }];
	}
}

- (BOOL)confirmDialog:(NSAlert *)alert suppressionIdentifier:(NSString *)identifier forAction:(void (^)(void))actionBlock
{
	NSParameterAssert(alert);
	__block BOOL didAct = YES;
	if (identifier && [PBGitDefaults isDialogWarningSuppressedForDialog:identifier]) {
		actionBlock();
		return didAct;
	}
	alert.showsSuppressionButton = YES;
	[alert beginSheetModalForWindow:self.window
				  completionHandler:^(NSModalResponse response) {
					  if (response != NSAlertFirstButtonReturn) {
						  didAct = NO;
						  return;
					  }
					  if (identifier && alert.suppressionButton.state == NSControlStateValueOn) [PBGitDefaults suppressDialogWarningForDialog:identifier];
					  actionBlock();
				  }];
	return didAct;
}

@end
#pragma clang diagnostic pop

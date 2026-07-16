#import "PBGitWindowController.h"

#import "PBCommitHookFailedSheet.h"
#import "PBError.h"
#import "PBGitCommitController.h"
#import "PBGitDefaults.h"
#import "PBGitRepository.h"
#import "PBGitXMessageSheet.h"

#pragma clang diagnostic push
// These methods remain declared on the stable primary interface.
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation PBGitWindowController (PBDialog)

- (IBAction)showRepositorySettings:(id)sender
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"Settings for %@", @"Repository settings title"), self.repository.projectName];
	alert.informativeText = NSLocalizedString(@"These settings apply only to this repository.", @"Repository settings detail");
	[alert addButtonWithTitle:NSLocalizedString(@"Done", @"Done button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button")];
	NSButton *notifications = [NSButton checkboxWithTitle:NSLocalizedString(@"Notify me when scheduled fetch finds new commits", @"Repository fetch notification checkbox") target:nil action:nil];
	notifications.state = [PBGitDefaults notifyAboutFetchedCommitsForRepositoryURL:self.repository.workingDirectoryURL] ? NSControlStateValueOn : NSControlStateValueOff;
	notifications.frame = NSMakeRect(0, 0, 390, 24);
	alert.accessoryView = notifications;
	[alert beginSheetModalForWindow:self.window
				  completionHandler:^(__unused NSModalResponse response) {
					  if (response == NSAlertFirstButtonReturn) {
						  [PBGitDefaults setNotifyAboutFetchedCommits:notifications.state == NSControlStateValueOn forRepositoryURL:self.repository.workingDirectoryURL];
					  }
				  }];
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

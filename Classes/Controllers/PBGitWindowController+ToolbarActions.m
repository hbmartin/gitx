#import "PBGitWindowController.h"

#import "GitX-Swift.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRevSpecifier.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation PBGitWindowController (PBToolbarActions)

- (IBAction)toolbarFetch:(id)sender
{
	[self fetchAllRemotes:sender];
}

- (IBAction)toolbarPull:(id)sender
{
	PBGitRef *head = self.repository.headRef.ref;
	if (head.isBranch) [self performPullForBranch:head remote:nil rebase:NO];
}

- (IBAction)toolbarPush:(id)sender
{
	PBGitRef *head = self.repository.headRef.ref;
	if (head.isBranch) [self performPushForBranch:head toRemote:nil];
}

- (IBAction)viewRemote:(id)sender
{
	[[PBRepositoryRemoteURLCoordinator shared] viewRemoteForRepository:self.repository presentingWindow:self.window];
}

@end
#pragma clang diagnostic pop

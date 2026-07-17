#import "PBGitRepository.h"

#import "PBGitCommit.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"
#import "GitX-Swift.h"

@interface PBGitRepository (PBServiceAccess)
- (PBRepositoryReferenceStore *)pb_referenceStore;
- (PBRepositoryRemoteService *)pb_remoteService;
- (PBRepositoryMutationService *)pb_mutationService;
- (PBRepositoryStashService *)pb_stashService;
- (PBRepositoryHookRunner *)pb_hookRunner;
@end

#pragma clang diagnostic push
// These methods remain declared on PBGitRepository's primary public interface;
// this category is only a source-level split of the stable façade.
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation PBGitRepository (PBServiceForwarding)

#pragma mark Stashes

- (NSArray<PBGitStash *> *)stashes
{
	return [self.pb_stashService stashes];
}

- (PBGitStash *)stashForRef:(PBGitRef *)ref
{
	return [self.pb_stashService stashForRef:ref];
}

- (void)publishStashInvalidation
{
	[self willChangeValueForKey:@"stashes"];
	[self didChangeValueForKey:@"stashes"];
}

- (BOOL)finishStashMutation:(BOOL)success
{
	[self publishStashInvalidation];
	return success;
}

- (BOOL)stashPop:(PBGitStash *)stash error:(NSError **)error
{
	return [self finishStashMutation:[self.pb_stashService popStash:stash error:error]];
}

- (BOOL)stashApply:(PBGitStash *)stash error:(NSError **)error
{
	return [self finishStashMutation:[self.pb_stashService applyStash:stash error:error]];
}

- (BOOL)stashDrop:(PBGitStash *)stash error:(NSError **)error
{
	return [self finishStashMutation:[self.pb_stashService dropStash:stash error:error]];
}

- (BOOL)stashSave:(NSError **)error
{
	return [self stashSaveWithKeepIndex:NO error:error];
}

- (BOOL)stashSaveWithKeepIndex:(BOOL)keepIndex error:(NSError **)error
{
	return [self finishStashMutation:[self.pb_stashService saveWithKeepIndex:keepIndex error:error]];
}

#pragma mark Remotes

- (NSArray<NSString *> *)remotes
{
	return [self.pb_remoteService remotes];
}

- (BOOL)hasRemotes
{
	return [self.pb_remoteService hasRemotes];
}

- (PBGitRef *)remoteRefForBranch:(PBGitRef *)branch error:(NSError **)error
{
	NSAssert(branch.ref != nil, @"Unexpected nil ref");
	return [self.pb_remoteService remoteRefForBranch:branch error:error];
}

- (BOOL)addRemote:(NSString *)remoteName withURL:(NSString *)URLString error:(NSError **)error
{
	return [self.pb_remoteService addRemote:remoteName withURL:URLString error:error];
}

- (void)scheduleRemoteReloadIfNeeded
{
	if (!self.pb_remoteService.commandWasLaunched) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		[self reloadRefs];
	});
}

- (BOOL)fetchRemoteForRef:(PBGitRef *)ref error:(NSError **)error
{
	BOOL success = [self.pb_remoteService fetchRemoteForRef:ref error:error];
	[self scheduleRemoteReloadIfNeeded];
	return success;
}

- (BOOL)pullBranch:(PBGitRef *)branchRef fromRemote:(PBGitRef *)remoteRef rebase:(BOOL)rebase error:(NSError **)error
{
	BOOL success = [self.pb_remoteService pullBranch:branchRef fromRemote:remoteRef rebase:rebase error:error];
	[self scheduleRemoteReloadIfNeeded];
	return success;
}

- (BOOL)pushBranch:(PBGitRef *)branchRef toRemote:(PBGitRef *)remoteRef error:(NSError **)error
{
	BOOL success = [self.pb_remoteService pushBranch:branchRef toRemote:remoteRef error:error];
	[self scheduleRemoteReloadIfNeeded];
	return success;
}

- (NSString *)lastPushOutput
{
	return self.pb_remoteService.lastPushOutput;
}

#pragma mark Mutations

- (BOOL)finishHistoryMutation:(BOOL)success
{
	if (success) {
		[self reloadRefs];
		[self readCurrentBranch];
	}
	return success;
}

- (BOOL)finishReferenceMutation:(BOOL)success
{
	if (success) [self reloadRefs];
	return success;
}

- (BOOL)checkoutRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self finishHistoryMutation:[self.pb_mutationService checkoutRefish:ref error:error]];
}

- (BOOL)checkoutFiles:(NSArray *)files fromRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self.pb_mutationService checkoutFiles:files fromRefish:ref error:error];
}

- (BOOL)mergeWithRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	NSString *headName = self.headRef.ref.shortName;
	return [self finishHistoryMutation:[self.pb_mutationService mergeWithRefish:ref headName:headName error:error]];
}

- (BOOL)cherryPickRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self finishHistoryMutation:[self.pb_mutationService cherryPickRefish:ref error:error]];
}

- (BOOL)resetRefish:(GTRepositoryResetType)mode to:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self finishHistoryMutation:[self.pb_mutationService resetRefish:mode to:ref error:error]];
}

- (BOOL)rebaseBranch:(id<PBGitRefish>)branch onRefish:(id<PBGitRefish>)upstream error:(NSError **)error
{
	NSParameterAssert(upstream != nil);
	return [self finishHistoryMutation:[self.pb_mutationService rebaseBranch:branch onRefish:upstream error:error]];
}

- (BOOL)createBranch:(NSString *)branchName atRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self finishReferenceMutation:[self.pb_mutationService createBranch:branchName atRefish:ref error:error]];
}

- (BOOL)createTag:(NSString *)tagName message:(NSString *)message atRefish:(id<PBGitRefish>)target error:(NSError **)error
{
	return [self finishReferenceMutation:[self.pb_mutationService createTag:tagName message:message atRefish:target error:error]];
}

- (BOOL)deleteRemote:(PBGitRef *)ref error:(NSError **)error
{
	if (![self.pb_remoteService deleteRemote:ref error:error]) return NO;
	NSString *remoteRef = [kGitXRemoteRefPrefix stringByAppendingString:ref.remoteName];
	for (PBGitRevSpecifier *revision in [self.branchesSet copy]) {
		PBGitRef *branch = revision.ref;
		if ([branch.ref hasPrefix:remoteRef]) {
			[self removeBranch:revision];
			[[self commitForRef:branch] removeRef:branch];
		}
	}
	[self reloadRefs];
	return YES;
}

- (NSString *)performDiff:(PBGitCommit *)startCommit against:(PBGitCommit *)diffCommit forFiles:(NSArray *)filePaths
{
	NSParameterAssert(startCommit);
	NSAssert(startCommit.repository == self, @"Different repo");
	if (diffCommit) NSAssert(diffCommit.repository == self, @"Different repo");
	return [self.pb_mutationService performDiff:startCommit against:diffCommit forFiles:filePaths];
}

- (BOOL)deleteRef:(PBGitRef *)ref error:(NSError **)error
{
	if (!ref) return NO;
	if ([ref refishType] == kGitXRemoteType) return [self deleteRemote:ref error:error];
	if (![self.pb_mutationService deleteReference:ref error:error]) return NO;
	[self removeBranch:[[PBGitRevSpecifier alloc] initWithRef:ref]];
	[[self commitForRef:ref] removeRef:ref];
	[self reloadRefs];
	return YES;
}

- (BOOL)updateReference:(PBGitRef *)ref toPointAtCommit:(PBGitCommit *)newCommit error:(NSError **)error
{
	if (![self.pb_mutationService updateReference:ref toPointAtCommit:newCommit error:error]) return NO;
	[self reloadRefs];
	return YES;
}

#pragma mark References and hooks

- (GTSubmodule *)submoduleAtPath:(NSString *)path error:(NSError **)error;
{
	return [self.pb_referenceStore submoduleAtPath:path error:error];
}

- (BOOL)executeHook:(NSString *)name error:(NSError **)error
{
	return [self executeHook:name arguments:@[] error:error];
}

- (BOOL)executeHook:(NSString *)name arguments:(NSArray *)arguments error:(NSError **)error
{
	return [self executeHook:name arguments:arguments output:NULL error:error];
}

- (NSString *)pathForHook:(NSString *)name
{
	return [self.pb_hookRunner pathForHook:name];
}

- (BOOL)executeHook:(NSString *)name arguments:(NSArray *)arguments output:(NSString **)outputPtr error:(NSError **)error
{
	NSParameterAssert(name != nil);
	return [self.pb_hookRunner executeHook:name arguments:arguments output:outputPtr error:error];
}

- (BOOL)hookExists:(NSString *)name
{
	return [self.pb_hookRunner hookExists:name];
}

- (BOOL)revisionExists:(NSString *)spec
{
	return [self.pb_referenceStore revisionExists:spec];
}

@end
#pragma clang diagnostic pop

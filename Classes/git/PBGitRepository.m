//
//  PBGitRepository.m
//  GitTest
//
//  Created by Pieter de Bie on 13-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitCommit.h"
#import "PBGitIndex.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"
#import "PBGitDefaults.h"
#import "PBGitRepositoryWatcher.h"
#import "PBRepositoryFinder.h"
#import "PBGitHistoryList.h"
#import "PBError.h"
#import "GitX-Swift.h"

NSString *const PBHookNameErrorKey = @"PBHookNameErrorKey";
@interface PBGitRepository () {
	__strong PBGitRepositoryWatcher *watcher;
	__strong GTRepository *_gtRepo;
	PBGitIndex *_index;
	PBRepositoryReferenceStore *_referenceStore;
	PBRepositoryRemoteService *_remoteService;
	PBRepositoryMutationService *_mutationService;
	PBRepositoryStashService *_stashService;
	PBRepositoryHookRunner *_hookRunner;
}

@property (nonatomic, strong) NSNumber *hasSVNRepoConfig;
@end

#pragma clang diagnostic push
// Public command selectors are intentionally implemented by the façade's
// PBServiceForwarding category so this nib- and subclass-compatible class can
// retain its existing Objective-C runtime surface while delegating behavior.
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation PBGitRepository

@synthesize revisionList, branchesSet, currentBranch, currentBranchFilter, hasChanged, refs;

#pragma mark Memory management

- (id)init
{
	self = [super init];
	if (!self) return nil;

	self.branchesSet = [NSMutableOrderedSet orderedSet];
	self.submodules = [NSMutableArray array];
	currentBranchFilter = [PBGitDefaults branchFilter];
	_referenceStore = [[PBRepositoryReferenceStore alloc] initWithRepository:self];
	_remoteService = [[PBRepositoryRemoteService alloc] initWithRepository:self];
	_mutationService = [[PBRepositoryMutationService alloc] initWithRepository:self];
	_stashService = [[PBRepositoryStashService alloc] initWithRepository:self];
	_hookRunner = [[PBRepositoryHookRunner alloc] initWithRepository:self];
	return self;
}

- (id)initWithURL:(NSURL *)repositoryURL error:(NSError **)error
{
	self = [self init];
	if (!self) return nil;

	NSError *gtError = nil;
	NSURL *repoURL = [PBRepositoryFinder gitDirForURL:repositoryURL];
	_gtRepo = [GTRepository repositoryWithURL:repoURL error:&gtError];
	if (!_gtRepo) {
		if (error) {
			*error = [NSError pb_errorWithDescription:NSLocalizedString(@"Repository initialization failed", @"")
										failureReason:[NSString stringWithFormat:NSLocalizedString(@"%@ does not appear to be a git repository.", @""), repositoryURL.path]
									  underlyingError:gtError];
		}
		return nil;
	}

	revisionList = [[PBGitHistoryList alloc] initWithRepository:self];

	[self reloadRefs];

	// Setup the FSEvents watcher to fire notifications when things change
	watcher = [[PBGitRepositoryWatcher alloc] initWithRepository:self];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(refreshWatcherPreference:)
												 name:NSUserDefaultsDidChangeNotification
											   object:nil];

	return self;
}

- (PBRepositoryReferenceStore *)pb_referenceStore
{
	return _referenceStore;
}
- (PBRepositoryRemoteService *)pb_remoteService
{
	return _remoteService;
}
- (PBRepositoryMutationService *)pb_mutationService
{
	return _mutationService;
}
- (PBRepositoryStashService *)pb_stashService
{
	return _stashService;
}
- (PBRepositoryHookRunner *)pb_hookRunner
{
	return _hookRunner;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[watcher stop];
}

- (void)refreshWatcherPreference:(NSNotification *)notification
{
	BOOL shouldWatch = [PBGitDefaults useRepositoryWatcher] &&
		![PBRepositoryRefreshPolicy shouldRefreshAfterApplicationActivation];
	if (shouldWatch) {
		[watcher start];
	} else {
		[watcher stop];
	}
}

#pragma mark Properties/General methods

- (NSURL *)getIndexURL
{
	NSError *error = nil;
	GTIndex *index = [self.gtRepo indexWithError:&error];
	if (index == nil) {
		NSLog(@"getIndexURL failed with error %@", error);
		return nil;
	}
	NSURL *result = index.fileURL;
	return result;
}

- (BOOL)isBareRepository
{
	return self.gtRepo.isBare;
}

- (BOOL)isShallowRepository
{
	return (BOOL)git_repository_is_shallow(self.gtRepo.git_repository);
}

- (BOOL)readHasSVNRemoteFromConfig
{
	NSError *error = nil;
	GTConfiguration *config = [self.gtRepo configurationWithError:&error];
	NSArray *allKeys = config.configurationKeys;
	for (NSString *key in allKeys) {
		if ([key hasPrefix:@"svn-remote."]) {
			return TRUE;
		}
	}
	return false;
}

- (BOOL)hasSVNRemote
{
	if (!self.hasSVNRepoConfig) {
		self.hasSVNRepoConfig = @([self readHasSVNRemoteFromConfig]);
	}
	return [self.hasSVNRepoConfig boolValue];
}

- (NSURL *)gitURL
{
	return self.gtRepo.gitDirectoryURL;
}

- (NSURL *)workingDirectoryURL
{
	return self.gtRepo.fileURL;
}

- (NSString *)workingDirectory
{
	return self.workingDirectoryURL.path;
}

- (void)forceUpdateRevisions
{
	[revisionList forceUpdate];
}

- (NSString *)projectName
{
	NSString *result = [self.workingDirectory lastPathComponent];
	if (!result) result = self.gitURL.lastPathComponent;
	return result;
}

- (NSString *)gitIgnoreFilename
{
	return [[self workingDirectory] stringByAppendingPathComponent:@".gitignore"];
}

- (void)reloadRefs
{
	PBRepositoryReferenceSnapshot *snapshot = [_referenceStore loadReferenceSnapshot];
	self->refs = [snapshot.references mutableCopy];
	NSMutableOrderedSet *oldBranches = [self.branchesSet mutableCopy];
	for (PBGitRevSpecifier *revSpec in snapshot.branches) {
		[self addBranch:revSpec];
		[oldBranches removeObject:revSpec];
	}
	for (PBGitRevSpecifier *branch in oldBranches)
		if ([branch isSimpleRef] && ![branch isEqual:[self headRef]])
			[self removeBranch:branch];
	self.submodules = [snapshot.submodules mutableCopy];
	[self willChangeValueForKey:@"refs"];
	[self willChangeValueForKey:@"stashes"];
	[self didChangeValueForKey:@"refs"];
	[self didChangeValueForKey:@"stashes"];
}

- (void)lazyReload
{
	if (!hasChanged) return;
	[self.revisionList updateHistory];
	hasChanged = NO;
}

- (PBGitRevSpecifier *)headRef
{
	return [_referenceStore headRef];
}
- (GTOID *)headOID
{
	return [_referenceStore headOID];
}
- (PBGitCommit *)headCommit
{
	return [self commitForOID:self.headOID];
}
- (GTOID *)OIDForRef:(PBGitRef *)ref
{
	return [_referenceStore OIDForRef:ref];
}

- (PBGitCommit *)commitForRef:(PBGitRef *)ref
{
	if (!ref) return nil;
	return [self commitForOID:[self OIDForRef:ref]];
}

- (PBGitCommit *)commitForOID:(GTOID *)sha
{
	if (!sha) return nil;
	NSArray *revList = revisionList.projectCommits;
	if (!revList) {
		[revisionList forceUpdate];
		revList = revisionList.projectCommits;
	}
	return [_referenceStore commitForOID:sha fromCommits:revList];
}

- (BOOL)isOIDOnSameBranch:(GTOID *)branchOID asOID:(GTOID *)testOID
{
	return [_referenceStore isOID:branchOID onSameBranchAsOID:testOID commits:revisionList.projectCommits];
}

- (BOOL)isOIDOnHeadBranch:(GTOID *)testOID
{
	if (!testOID) return NO;
	GTOID *headOID = self.headOID;
	if ([testOID isEqual:headOID]) return YES;
	return [self isOIDOnSameBranch:headOID asOID:testOID];
}

- (BOOL)isRefOnHeadBranch:(PBGitRef *)testRef
{
	if (!testRef) return NO;
	return [self isOIDOnHeadBranch:[self OIDForRef:testRef]];
}

- (BOOL)checkRefFormat:(NSString *)refName
{
	return [_referenceStore checkRefFormat:refName];
}
- (BOOL)refExists:(PBGitRef *)ref
{
	return [_referenceStore refExists:ref];
}
- (PBGitRef *)refForName:(NSString *)name
{
	return [_referenceStore refForName:name];
}
- (NSArray<PBGitRevSpecifier *> *)branches
{
	return [self.branchesSet array];
}

// Returns either this object, or an existing, equal object
- (PBGitRevSpecifier *)addBranch:(PBGitRevSpecifier *)branch
{
	if ([[branch parameters] count] == 0) branch = [self headRef];
	if ([self.branchesSet containsObject:branch]) return branch;
	NSIndexSet *newIndex = [NSIndexSet indexSetWithIndex:[self.branches count]];
	[self willChange:NSKeyValueChangeInsertion valuesAtIndexes:newIndex forKey:@"branches"];
	[self.branchesSet addObject:branch];
	[self didChange:NSKeyValueChangeInsertion valuesAtIndexes:newIndex forKey:@"branches"];
	return branch;
}

- (BOOL)removeBranch:(PBGitRevSpecifier *)branch
{
	if ([self.branchesSet containsObject:branch]) {
		NSIndexSet *oldIndex = [NSIndexSet indexSetWithIndex:[self.branches indexOfObject:branch]];
		[self willChange:NSKeyValueChangeRemoval valuesAtIndexes:oldIndex forKey:@"branches"];
		[self.branchesSet removeObject:branch];
		[self didChange:NSKeyValueChangeRemoval valuesAtIndexes:oldIndex forKey:@"branches"];
		return YES;
	}
	return NO;
}

- (void)readCurrentBranch
{
	self.currentBranch = [self addBranch:[self headRef]];
}

- (void)setCurrentBranch:(PBGitRevSpecifier *)newCurrentBranch
{
	currentBranch = newCurrentBranch;
	[revisionList updateHistory];
}

- (void)setCurrentBranchFilter:(NSInteger)newCurrentBranchFilter
{
	currentBranchFilter = newCurrentBranchFilter;
	[revisionList updateHistory];
}

- (void)setHasChanged:(BOOL)newHasChanged
{
	hasChanged = newHasChanged;
	[revisionList forceUpdate];
}


- (BOOL)ignoreFilePaths:(NSArray *)filePaths error:(NSError **)error
{
	NSString *gitIgnoreName = [self gitIgnoreFilename];
	if (!gitIgnoreName) {
		if (error) {
			*error = [NSError pb_errorWithDescription:NSLocalizedString(@"Ignore file update failed", @"")
										failureReason:NSLocalizedString(@"This repository does not have a working directory.", @"")];
		}
		return NO;
	}

	PBRepositoryIgnoreFileService *service =
		[[PBRepositoryIgnoreFileService alloc] initWithFileURL:[NSURL fileURLWithPath:gitIgnoreName]];
	return [service appendPaths:filePaths error:error];
}

- (PBGitIndex *)index
{
	if (!_index) {
		_index = [[PBGitIndex alloc] initWithRepository:self];
	}
	return _index;
}

@end
#pragma clang diagnostic pop

//
//  PBGitRepository.h
//  GitTest
//
//  Created by Pieter de Bie on 13-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <ObjectiveGit/GTRepository+Reset.h>
#import "PBGitRefish.h"

@class PBGitHistoryList;
@class PBGitRevSpecifier;
@protocol PBGitRefish;
@class PBGitRef;
@class PBGitStash;
@class PBGitRepositoryDocument;
@class GTRepository;
@class GTConfiguration;

NS_ASSUME_NONNULL_BEGIN

extern NSString *PBGitRepositoryDocumentType;

/** NSError user info key - hook name */
extern NSString *const PBHookNameErrorKey;

typedef enum branchFilterTypes {
	kGitXAllBranchesFilter = 0,
	kGitXLocalRemoteBranchesFilter,
	kGitXSelectedBranchFilter
} PBGitXBranchFilterType;

@class PBGitWindowController;
@class PBGitCommit;
@class PBGitIndex;
@class GTOID;
@class PBGitRepositoryWatcher;
@class GTSubmodule;

@interface PBGitRepository : NSObject

@property (nullable, nonatomic, weak) PBGitRepositoryDocument *document; // Backward-compatibility while PBGitRepository gets "modelized";

@property (nonatomic, assign) BOOL hasChanged;
@property (nonatomic, assign) NSInteger currentBranchFilter;

@property (nullable, readonly, getter=getIndexURL) NSURL *indexURL;

@property (nullable, nonatomic, strong) PBGitHistoryList *revisionList;
@property (nonatomic, readonly, strong) NSArray<PBGitStash *> *stashes;
@property (nonatomic, readonly, strong) NSArray<PBGitRevSpecifier *> *branches;
@property (nonatomic, strong) NSMutableOrderedSet<PBGitRevSpecifier *> *branchesSet;
@property (nullable, nonatomic, strong) PBGitRevSpecifier *currentBranch;
@property (nullable, nonatomic, strong) NSMutableDictionary<GTOID *, NSMutableArray<PBGitRef *> *> *refs;
@property (nullable, readonly, strong) GTRepository *gtRepo;
@property (nonatomic, readonly) BOOL isShallowRepository;

@property (nonatomic, strong) NSMutableArray<GTSubmodule *> *submodules;
@property (readonly, strong) PBGitIndex *index;

// Designated initializer
- (nullable instancetype)initWithURL:(NSURL *)repositoryURL error:(NSError *_Nullable *_Nullable)error;

- (BOOL)addRemote:(NSString *)remoteName withURL:(NSString *)URLString error:(NSError *_Nullable *_Nullable)error;
- (BOOL)fetchRemoteForRef:(nullable PBGitRef *)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)pullBranch:(PBGitRef *)branchRef fromRemote:(nullable PBGitRef *)remoteRef rebase:(BOOL)rebase error:(NSError *_Nullable *_Nullable)error;
- (BOOL)pushBranch:(nullable PBGitRef *)branchRef toRemote:(nullable PBGitRef *)remoteRef error:(NSError *_Nullable *_Nullable)error;

- (BOOL)checkoutRefish:(id<PBGitRefish>)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)checkoutFiles:(nullable NSArray<NSString *> *)files fromRefish:(id<PBGitRefish>)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)mergeWithRefish:(id<PBGitRefish>)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)cherryPickRefish:(nullable id<PBGitRefish>)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)resetRefish:(GTRepositoryResetType)mode to:(nullable id<PBGitRefish>)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)rebaseBranch:(nullable id<PBGitRefish>)branch onRefish:(id<PBGitRefish>)upstream error:(NSError *_Nullable *_Nullable)error;
- (BOOL)createBranch:(nullable NSString *)branchName atRefish:(nullable id<PBGitRefish>)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)createTag:(nullable NSString *)tagName message:(NSString *)message atRefish:(id<PBGitRefish>)commitSHA error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteRemote:(nullable PBGitRef *)ref error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteRef:(nullable PBGitRef *)ref error:(NSError *_Nullable *_Nullable)error;

- (BOOL)stashPop:(PBGitStash *)stash error:(NSError *_Nullable *_Nullable)error;
- (BOOL)stashApply:(PBGitStash *)stash error:(NSError *_Nullable *_Nullable)error;
- (BOOL)stashDrop:(PBGitStash *)stash error:(NSError *_Nullable *_Nullable)error;
- (BOOL)stashSave:(NSError *_Nullable *_Nullable)error;
- (BOOL)stashSaveWithKeepIndex:(BOOL)keepIndex error:(NSError *_Nullable *_Nullable)error;

- (BOOL)ignoreFilePaths:(NSArray<NSString *> *)filePaths error:(NSError *_Nullable *_Nullable)error;

- (BOOL)updateReference:(PBGitRef *)ref toPointAtCommit:(PBGitCommit *)newCommit error:(NSError *_Nullable *_Nullable)error;
- (NSString *)performDiff:(PBGitCommit *)startCommit against:(nullable PBGitCommit *)diffCommit forFiles:(nullable NSArray<NSString *> *)filePaths;

- (nullable NSURL *)gitURL;

- (BOOL)executeHook:(NSString *)name error:(NSError *_Nullable *_Nullable)error;
- (BOOL)executeHook:(NSString *)name arguments:(NSArray<NSString *> *)arguments error:(NSError *_Nullable *_Nullable)error;
- (BOOL)executeHook:(NSString *)name arguments:(NSArray<NSString *> *)arguments output:(NSString *_Nullable *_Nullable)outputPtr error:(NSError *_Nullable *_Nullable)error;
- (BOOL)hookExists:(NSString *)name;

- (nullable NSString *)workingDirectory;
- (nullable NSURL *)workingDirectoryURL;
- (nullable NSString *)projectName;

- (nullable NSString *)gitIgnoreFilename;
- (BOOL)isBareRepository;

- (BOOL)hasSVNRemote;

- (void)reloadRefs;
- (void)lazyReload;
- (nullable PBGitRevSpecifier *)headRef;
- (nullable GTOID *)headOID;
- (nullable PBGitCommit *)headCommit;
- (nullable GTOID *)OIDForRef:(nullable PBGitRef *)ref;
- (nullable PBGitCommit *)commitForRef:(nullable PBGitRef *)ref;
- (nullable PBGitCommit *)commitForOID:(nullable GTOID *)sha;
- (BOOL)isOIDOnSameBranch:(nullable GTOID *)baseOID asOID:(nullable GTOID *)testOID;
- (BOOL)isOIDOnHeadBranch:(nullable GTOID *)testOID;
- (nullable PBGitStash *)stashForRef:(PBGitRef *)ref;
- (BOOL)isRefOnHeadBranch:(nullable PBGitRef *)testRef;
- (BOOL)checkRefFormat:(NSString *)refName;
- (BOOL)refExists:(nullable PBGitRef *)ref;
- (nullable PBGitRef *)refForName:(nullable NSString *)name;

- (nullable NSArray<NSString *> *)remotes;
- (BOOL)hasRemotes;
- (nullable PBGitRef *)remoteRefForBranch:(PBGitRef *)branch error:(NSError *_Nullable *_Nullable)error;

- (void)readCurrentBranch;
- (nullable PBGitRevSpecifier *)addBranch:(PBGitRevSpecifier *)rev;
- (BOOL)removeBranch:(PBGitRevSpecifier *)rev;

- (BOOL)revisionExists:(NSString *)spec;

- (void)forceUpdateRevisions;
- (nullable NSURL *)getIndexURL;

- (nullable GTSubmodule *)submoduleAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

@end


NS_ASSUME_NONNULL_END

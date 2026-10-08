//
//  PBGitIndex.h
//  GitX
//
//  Created by Pieter de Bie on 9/12/09.
//  Copyright 2009 Pieter de Bie. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class PBGitRepository;
@class PBChangedFile;

NS_ASSUME_NONNULL_BEGIN

/*
 * Notifications this class will send
 */

// Refreshing index
extern NSString *PBGitIndexIndexRefreshStatus;
extern NSString *PBGitIndexIndexRefreshFailed;
extern NSString *PBGitIndexFinishedIndexRefresh;

// The "indexChanges" array has changed
extern NSString *PBGitIndexIndexUpdated;

// Committing files
extern NSString *PBGitIndexCommitStatus;
extern NSString *PBGitIndexCommitOutput;
extern NSString *PBGitIndexCommitFailed;
extern NSString *PBGitIndexCommitHookFailed;
extern NSString *PBGitIndexFinishedCommit;

// Changing to amend
extern NSString *PBGitIndexAmendMessageAvailable;

// This is for general operations, like applying a patch
extern NSString *PBGitIndexOperationFailed;


// Represents a git index for a given work tree.
// As a single git repository can have multiple trees,
// the tree has to be given explicitly, even though
// multiple trees is not yet supported in GitX
@interface PBGitIndex : NSObject

// Whether we want the changes for amending,
// or for making a new commit.
@property (assign, getter=isAmend) BOOL amend;
@property (weak, readonly, nullable) PBGitRepository *repository;
// Interactive methods report admission immediately and complete on main. Rows remain at their last coherent
// snapshot until the corresponding refresh completes; UI mutation controls wait.
@property (readonly) BOOL mutationReconciliationPending;
@property (readonly) NSUInteger snapshotRevision;
// Selection changes inside Cocoa publication are automatic, rather than user input.
@property (readonly) BOOL publishingSnapshot;
@property (readonly) BOOL submissionActive;
@property (readonly) BOOL awaitingHookDecision;

// A list of PBChangedFile's with differences between the work tree and the index
// This method is KVO-aware, so changes when any of the index-modifying methods are called
// (including -refresh)
@property (readonly, retain) NSArray<PBChangedFile *> *indexChanges;

- (instancetype)initWithRepository:(PBGitRepository *)repository;

// Refresh the index
- (void)refresh;

// Update the stat cache (git update-index --refresh). Clears phantom "modified"
// entries caused by stat mismatches. Call on app activation, not on every change.
- (void)refreshStatCache;

// Run the prepare-git-msg hook and return the result
- (nullable NSString *)createPrepareCommitMessage;

- (void)commitWithMessage:(NSString *)commitMessage andVerify:(BOOL)doVerify;
- (void)retryCommitWithoutVerification;
- (void)cancelCommitSubmission;

// Inter-file changes:
- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles;
- (BOOL)unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles;
- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles;
- (void)discardChangesForFiles:(NSArray<PBChangedFile *> *)discardFiles;

// Asynchronous interactive operations. Boolean means admitted; completion is the actual result.
- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)files completion:(void (^)(BOOL, NSError *_Nullable))completion;
- (BOOL)unstageFiles:(NSArray<PBChangedFile *> *)files completion:(void (^)(BOOL, NSError *_Nullable))completion;
- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles completion:(void (^)(BOOL, NSError *_Nullable))completion;
- (BOOL)discardChangesForFiles:(NSArray<PBChangedFile *> *)files completion:(void (^)(BOOL, NSError *_Nullable))completion;
- (BOOL)applyPatch:(NSString *)patch stage:(BOOL)stage reverse:(BOOL)reverse completion:(void (^)(BOOL, NSError *_Nullable))completion;
- (void)close;
@property (readonly) NSUInteger writerPendingCount;
@property (readonly) NSUInteger writerActiveCount;

// Intra-file changes
- (BOOL)applyPatch:(NSString *)hunk stage:(BOOL)stage reverse:(BOOL)reverse;
- (nullable NSString *)diffForFile:(PBChangedFile *)file staged:(BOOL)staged contextLines:(NSUInteger)context;
- (nullable NSString *)diffForFile:(PBChangedFile *)file staged:(BOOL)staged contextLines:(NSUInteger)context ignoreWhitespace:(BOOL)ignoreWhitespace;
- (nullable NSArray<NSString *> *)diffToolArgumentsForFile:(PBChangedFile *)file
													staged:(BOOL)staged
													 error:(NSError *_Nullable *_Nullable)error
	NS_SWIFT_NAME(diffToolArguments(for:staged:error:)) __attribute__((swift_error(none)));
- (nullable NSArray<NSString *> *)literalArgumentsForRawPath:(NSData *)rawPath
											commandArguments:(NSArray<NSString *> *)commandArguments
													   error:(NSError *_Nullable *_Nullable)error
	NS_SWIFT_NAME(literalArguments(forRawPath:commandArguments:error:)) __attribute__((swift_error(none)));

@end

NS_ASSUME_NONNULL_END

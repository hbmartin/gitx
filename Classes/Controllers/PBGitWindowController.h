//
//  PBGitWindowController.h
//  GitX
//
//  Created by Pieter de Bie on 16-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PBHistorySearchMode.h"

@class PBViewController;
@class PBGitSidebarController;
@class PBGitHistoryController;
@class PBGitRepository;
@class RJModalRepoSheet;
@class PBGitRef;
@class PBGitCommit;
@class PBGitRepositoryDocument;

NS_ASSUME_NONNULL_BEGIN

@interface PBGitWindowController : NSWindowController <NSWindowDelegate, NSMenuItemValidation>

@property (nonatomic, strong, nullable) PBGitRepository *repository;
/* This is assign because that's what NSWindowController says :-S */
@property (assign, nullable) PBGitRepositoryDocument *document;
@property (readonly, nullable) PBGitHistoryController *historyViewController;
@property (readonly, nullable) PBGitSidebarController *sidebarViewController;

- (instancetype)init;

- (void)changeContentController:(nullable PBViewController *)controller;
- (BOOL)isUncommittedChangesSelected;

- (void)showCommitHookFailedSheet:(NSString *)messageText infoText:(NSString *)infoText retryHandler:(nullable void (^)(void))retryHandler;

- (void)showMessageSheet:(NSString *)messageText infoText:(NSString *)infoText;
- (void)showErrorSheet:(NSError *)error;


- (void)openURLs:(nullable NSArray<NSURL *> *)fileURLs;
- (void)revealURLsInFinder:(nullable NSArray<NSURL *> *)fileURLs;

- (IBAction)showUncommittedChanges:(nullable id)sender;
- (IBAction)showHistoryView:(nullable id)sender;
- (IBAction)toggleAmendCommit:(nullable id)sender;
- (IBAction)openFiles:(nullable id)sender;
- (IBAction)revealInFinder:(nullable id)sender;
- (IBAction)openInTerminal:(nullable id)sender;
- (IBAction)refresh:(nullable id)sender;
- (IBAction)jumpToCheckedOutBranch:(nullable id)sender;
- (IBAction)showRepositorySettings:(nullable id)sender;
- (IBAction)viewRemote:(nullable id)sender;
- (IBAction)toolbarFetch:(nullable id)sender;
- (IBAction)toolbarPull:(nullable id)sender;
- (IBAction)toolbarPush:(nullable id)sender;

- (IBAction)checkout:(nullable id)sender;
- (IBAction)createBranch:(nullable id)sender;
- (IBAction)createTag:(nullable id)sender;
- (IBAction)merge:(nullable id)sender;
- (IBAction)deleteRef:(nullable id)sender;
- (IBAction)rebase:(nullable id)sender;
- (IBAction)rebaseHeadBranch:(nullable id)sender;
- (IBAction)cherryPick:(nullable id)sender;
- (IBAction)resetSoft:(nullable id)sender;

- (IBAction)showAddRemoteSheet:(nullable id)sender GITX_DEPRECATED;
- (IBAction)addRemote:(nullable id)sender;
- (IBAction)fetchRemote:(nullable id)sender;
- (IBAction)fetchAllRemotes:(nullable id)sender;

- (IBAction)pullRemote:(nullable id)sender;
- (IBAction)pullRebaseRemote:(nullable id)sender;
- (IBAction)pullDefaultRemote:(nullable id)sender;
- (IBAction)pullRebaseDefaultRemote:(nullable id)sender;

- (IBAction)pushUpdatesToRemote:(nullable id)sender;
- (IBAction)pushDefaultRemoteForRef:(nullable id)sender;
- (IBAction)pushToRemote:(nullable id)sender;

- (IBAction)stashSave:(nullable id)sender;
- (IBAction)stashSaveWithKeepIndex:(nullable id)sender;
- (IBAction)stashPop:(nullable id)sender;
- (IBAction)stashApply:(nullable id)sender;
- (IBAction)stashDrop:(nullable id)sender;

- (IBAction)diffWithHEAD:(nullable id)sender;
- (IBAction)stashViewDiff:(nullable id)sender;
- (IBAction)showTagInfoSheet:(nullable id)sender;

- (void)setHistorySearch:(NSString *)searchString mode:(PBHistorySearchMode)mode;

- (void)performFetchForRef:(nullable PBGitRef *)ref;
- (void)performPullForBranch:(PBGitRef *)branchRef remote:(nullable PBGitRef *)remoteRef rebase:(BOOL)rebase;
- (void)performPushForBranch:(nullable PBGitRef *)branchRef toRemote:(nullable PBGitRef *)remoteRef;
- (void)performPushForBranch:(nullable PBGitRef *)branchRef
					toRemote:(nullable PBGitRef *)remoteRef
		requiresConfirmation:(BOOL)requiresConfirmation;

@end

@interface PBGitWindowController (PBDialog)
/**
 * Ask the user to confirm an action.
 *
 * @param alert The alert to show.
 * @param identifier The user default to check to suppress the alert completely.
 * @param actionBlock The action to perform.
 * @return YES if the action was performed, NO if the user cancelled.
 */
- (BOOL)confirmDialog:(NSAlert *)alert suppressionIdentifier:(nullable NSString *)identifier forAction:(void (^)(void))actionBlock;
@end

NS_ASSUME_NONNULL_END

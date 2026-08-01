#import <Cocoa/Cocoa.h>

#import "PBHistorySearchMode.h"
#import "PBGitRepository_PBGitBinarySupport.h"

@class PBViewController;
@class PBGitSidebarController;
@class PBGitHistoryController;
@class PBGitRepository;
@class PBGitRef;
@class PBGitRepositoryDocument;

NS_ASSUME_NONNULL_BEGIN

/// Narrow test-only mirror of GitX-Swift.h's PBGitWindowController interface.
/// App-hosted tests cannot import the complete generated header because they also
/// carry focused declarations for other Swift production types.
@interface PBGitWindowController : NSWindowController <NSWindowDelegate, NSMenuItemValidation>

@property (nonatomic, strong, nullable) PBGitRepository *repository;
@property (assign, nullable) PBGitRepositoryDocument *document;
@property (readonly, nullable) PBGitHistoryController *historyViewController;
@property (readonly, nullable) PBGitSidebarController *sidebarViewController;

- (instancetype)init;

- (void)changeContentController:(nullable PBViewController *)controller;
- (BOOL)isUncommittedChangesSelected;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem NS_SWIFT_NAME(validateMenuItem(_:));

- (void)showCommitHookFailedSheet:(NSString *)messageText
						 infoText:(NSString *)infoText
					retryHandler:(nullable void (^)(void))retryHandler;
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
- (IBAction)newPullRequest:(nullable id)sender;

- (IBAction)checkout:(nullable id)sender;
- (IBAction)createBranch:(nullable id)sender;
- (IBAction)createTag:(nullable id)sender;
- (IBAction)merge:(nullable id)sender;
- (IBAction)deleteRef:(nullable id)sender;
- (IBAction)rebase:(nullable id)sender;
- (IBAction)rebaseHeadBranch:(nullable id)sender;
- (IBAction)cherryPick:(nullable id)sender;
- (IBAction)resetSoft:(nullable id)sender;

- (IBAction)showAddRemoteSheet:(nullable id)sender;
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
- (void)performPullForBranch:(PBGitRef *)branchRef
					  remote:(nullable PBGitRef *)remoteRef
					  rebase:(BOOL)rebase;
- (void)performPushForBranch:(nullable PBGitRef *)branchRef toRemote:(nullable PBGitRef *)remoteRef;
- (void)performPushForBranch:(nullable PBGitRef *)branchRef
					toRemote:(nullable PBGitRef *)remoteRef
		requiresConfirmation:(BOOL)requiresConfirmation;
- (void)performPushForBranch:(nullable PBGitRef *)branchRef
					toRemote:(nullable PBGitRef *)remoteRef
		requiresConfirmation:(BOOL)requiresConfirmation
	initiallyCreatePullRequest:(BOOL)initiallyCreatePullRequest;
- (void)presentNewPullRequest;
- (BOOL)openForgeRevision:(NSString *)revision;
- (BOOL)openForgeComparisonFrom:(NSString *)base
							 to:(NSString *)head NS_SWIFT_NAME(openForgeComparison(base:head:));

- (BOOL)confirmDialog:(NSAlert *)alert
	suppressionIdentifier:(nullable NSString *)identifier
				 forAction:(void (^)(void))actionBlock;
- (BOOL)confirmDialog:(NSAlert *)alert
	suppressionIdentifier:(nullable NSString *)identifier
				  onCancel:(void (^)(void))cancelBlock
				 forAction:(void (^)(void))actionBlock;

@end

/// Objective-C layout barrier for Swift test doubles that subclass this
/// compatibility mirror of the production Swift window controller.
@interface PBHistoryWindowControllerTestBase : PBGitWindowController
@end

/// DEBUG app-target proof bridge. These selectors execute the shipped GitX
/// module rather than the Swift source copies linked into the test bundle.
@interface PBMilestone2ProductCoverageHarness : NSObject
+ (uint64_t)synchronousProof;
+ (void)asyncProofWithCompletion:(void (^)(uint64_t proof))completion;
@end

@interface PBMilestone2CompositionCoverageHarness : NSObject
+ (uint64_t)synchronousProof;
+ (void)asynchronousProofWithCompletionHandler:(void (^)(uint64_t proof))completionHandler;
+ (void)reviewReadProofWithCompletionHandler:(void (^)(uint64_t proof))completionHandler;
+ (void)reviewMutationProofWithCompletionHandler:(void (^)(uint64_t proof))completionHandler;
+ (BOOL)reviewApplicationProofWithRepository:(PBGitRepository *)repository;
+ (void)reviewApplicationRemoteBindingProofWithRepository:(PBGitRepository *)repository
										completionHandler:(void (^)(uint64_t proof))completionHandler
	NS_SWIFT_NAME(reviewApplicationRemoteBindingProof(repository:completionHandler:));
+ (void)reviewApplicationLocalBindingProofWithRepository:(PBGitRepository *)repository
									   completionHandler:(void (^)(uint64_t proof))completionHandler
	NS_SWIFT_NAME(reviewApplicationLocalBindingProof(repository:completionHandler:));
@end

@interface PBMilestone3ProductCoverageHarness : NSObject
+ (BOOL)repositoryForgeViewStateProofWithRepository:(PBGitRepository *)repository;
+ (BOOL)collaborationCloseLifecycleProofWithRepository:(PBGitRepository *)repository;
+ (BOOL)refreshCompletionProofWithRepository:(PBGitRepository *)repository;
@end

@interface PBWindowSessionCoordinator : NSObject
@property (class, nonatomic, readonly, strong) PBWindowSessionCoordinator *shared;
- (void)applicationDidFinishLaunching;
@end

NS_ASSUME_NONNULL_END

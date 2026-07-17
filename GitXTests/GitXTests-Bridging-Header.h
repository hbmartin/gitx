#import <Quartz/Quartz.h>
#import "GitXRelativeDateFormatter.h"
#import "PBRepositoryFinder.h"
#import "PBMacros.h"
#import "PBGitRevSpecifier.h"
#import "PBGitDefaults.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitHistoryController.h"
#import "PBGitCommit.h"
#import "PBGitIndex.h"
#import "PBGitStash.h"
#import "PBUncommittedChanges.h"
#import "PBHighlighting.h"
#import "PBNativeContentView.h"
#import "PBTask.h"
#import "PBProcessEnvironment.h"
#import "PBGitRevisionCell.h"
#import "PBHistorySearchController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBImageRevisionPolicy : NSObject
+ (NSArray<NSString *> *)revisionsForCommitSHA:(NSString *)commitSHA
                                     parentSHA:(nullable NSString *)parentSHA
                                  workingState:(BOOL)workingState
    NS_SWIFT_NAME(revisions(commitSHA:parentSHA:workingState:));
@end

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

@interface PBRemoteSidebarSyncPlan : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *namesToAdd;
@property (nonatomic, copy, readonly) NSArray<NSString *> *namesToRemove;
+ (instancetype)planWithConfiguredRemoteNames:(NSArray<NSString *> *)configuredRemoteNames
                           existingRemoteNames:(NSArray<NSString *> *)existingRemoteNames
                           nonEmptyRemoteNames:(NSArray<NSString *> *)nonEmptyRemoteNames
    NS_SWIFT_NAME(plan(configuredRemoteNames:existingRemoteNames:nonEmptyRemoteNames:));
@end

@interface PBCommitRenderInput : NSObject
@property (nonatomic, copy, readonly) NSString *sha;
@property (nonatomic, copy, readonly, nullable) NSString *parentSHA;
@property (nonatomic, copy, readonly) NSString *shortName;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSArray<NSString *> *imageRevisions;
- (instancetype)initWithSHA:(NSString *)sha
                  parentSHA:(nullable NSString *)parentSHA
                  shortName:(NSString *)shortName
                    subject:(NSString *)subject
                     author:(NSString *)author
                 authorDate:(NSString *)authorDate;
@end

@interface PBWorkingStateRefreshPolicy : NSObject
+ (BOOL)shouldReplaceDisplayedDiff:(nullable NSString *)displayedDiff
                      renderedDiff:(NSString *)renderedDiff;
@end

@interface PBRewindOverlayView : NSView
- (instancetype)initWithFrame:(NSRect)frameRect;
@end

@protocol PBGitCommandRunning <NSObject>
- (nullable NSString *)outputWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
- (BOOL)launchWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
@end

@interface PBRepositoryReferenceStore : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (nullable PBGitRef *)refForName:(nullable NSString *)name;
@end

@interface PBRepositoryRemoteService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (nullable NSArray<NSString *> *)remotes;
- (BOOL)addRemote:(NSString *)remoteName withURL:(NSString *)URLString error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)fetchRemoteForRef:(nullable PBGitRef *)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)pullBranch:(nullable PBGitRef *)branchRef fromRemote:(nullable PBGitRef *)remoteRef rebase:(BOOL)rebase error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)pushBranch:(nullable PBGitRef *)branchRef toRemote:(nullable PBGitRef *)remoteRef error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)deleteRemote:(nullable PBGitRef *)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

@interface PBRepositoryMutationService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (BOOL)checkoutRefish:(id<PBGitRefish>)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)checkoutFiles:(nullable NSArray<NSString *> *)files fromRefish:(id<PBGitRefish>)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

@interface PBRepositoryStashService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (BOOL)saveWithKeepIndex:(BOOL)keepIndex error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

@interface PBIndexStatusEntry : NSObject
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSInteger status;
@property (nonatomic, readonly, nullable) NSString *commitBlobMode;
@property (nonatomic, readonly, nullable) NSString *commitBlobSHA;
@end

@interface PBIndexStatusParser : NSObject
- (nullable NSDictionary<NSString *, PBIndexStatusEntry *> *)parseTrackedData:(nullable NSData *)data
															 error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (nullable NSDictionary<NSString *, PBIndexStatusEntry *> *)parseUntrackedData:(nullable NSData *)data
															   error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

@interface PBIndexFileSnapshot : NSObject
@property (nonatomic, readonly) NSString *path;
@property (nonatomic) NSInteger status;
@property (nonatomic, nullable) NSString *commitBlobMode;
@property (nonatomic, nullable) NSString *commitBlobSHA;
@property (nonatomic) BOOL hasStagedChanges;
@property (nonatomic) BOOL hasUnstagedChanges;
- (instancetype)initWithPath:(NSString *)path
					  status:(NSInteger)status
			  commitBlobMode:(nullable NSString *)commitBlobMode
			   commitBlobSHA:(nullable NSString *)commitBlobSHA
		 hasStagedChanges:(BOOL)hasStagedChanges
	  hasUnstagedChanges:(BOOL)hasUnstagedChanges;
@end

@interface PBIndexSnapshotReducer : NSObject
- (NSArray<PBIndexFileSnapshot *> *)reducePrevious:(NSArray<PBIndexFileSnapshot *> *)previous
												 staged:(nullable NSDictionary<NSString *, PBIndexStatusEntry *> *)staged
												unstaged:(nullable NSDictionary<NSString *, PBIndexStatusEntry *> *)unstaged
											   untracked:(nullable NSDictionary<NSString *, PBIndexStatusEntry *> *)untracked;
@end

@interface PBNativeContentSection : NSObject
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSString *context;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *entries;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *imageSource;
@property (nonatomic, readonly) NSString *displayTitle;
@property (nonatomic, readonly) NSString *highlightingPath;
- (instancetype)initWithDictionary:(NSDictionary<NSString *, id> *)dictionary;
+ (NSArray<PBNativeContentSection *> *)sectionsWithDictionaries:(NSArray<NSDictionary<NSString *, id> *> *)dictionaries;
@end

@class PBNativeDiffDocument;

@interface PBDiffDocumentParser : NSObject
- (PBNativeDiffDocument *)parseText:(NSString *)text fallbackPath:(NSString *)fallbackPath;
- (NSString *)pathForDiffHeaderAtIndex:(NSInteger)headerIndex lines:(NSArray<NSString *> *)lines;
@end

@interface PBNativeDiffFile : NSObject
@property (nonatomic, readonly) NSInteger startIndex;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSArray<NSString *> *headerLines;
@end

@interface PBNativeDiffHunk : NSObject
@property (nonatomic, readonly) NSInteger startIndex;
@property (nonatomic, readonly) NSInteger endIndex;
@property (nonatomic, readonly) NSArray<NSString *> *lines;
@property (nonatomic, readonly) NSArray<NSString *> *fileHeader;
@property (nonatomic, readonly) NSString *patch;
- (NSIndexSet *)blockIndexesStartingAtIndex:(NSInteger)index;
@end

@interface PBNativeDiffDocument : NSObject
@property (nonatomic, readonly) NSArray<NSString *> *lines;
@property (nonatomic, readonly) NSString *fallbackPath;
@property (nonatomic, readonly) NSDictionary<NSNumber *, PBNativeDiffFile *> *filesByStartIndex;
@property (nonatomic, readonly) NSDictionary<NSNumber *, PBNativeDiffHunk *> *hunksByStartIndex;
@end

@interface PBPartialPatchBuilder : NSObject
- (nullable NSString *)patchWithFileHeader:(NSArray<NSString *> *)fileHeader
                                 hunkLines:(NSArray<NSString *> *)hunkLines
                           selectedIndexes:(NSIndexSet *)selectedIndexes
                                   reverse:(BOOL)reverse;
@end

@interface PBNativeRenderResult : NSObject
@property (nonatomic, readonly) NSAttributedString *attributedString;
@property (nonatomic, readonly) NSDictionary<NSString *, NSDictionary<NSString *, id> *> *linkPayloads;
@end

@interface PBNativeTextRenderer : NSObject
- (instancetype)initWithBaseAttributes:(NSDictionary<NSAttributedStringKey, id> *)baseAttributes
					titleAttributes:(NSDictionary<NSAttributedStringKey, id> *)titleAttributes;
- (PBNativeRenderResult *)renderSourceSections:(NSArray<PBNativeContentSection *> *)sections;
- (PBNativeRenderResult *)renderBlameSections:(NSArray<PBNativeContentSection *> *)sections;
- (PBNativeRenderResult *)renderHistorySections:(NSArray<PBNativeContentSection *> *)sections;
@end

@interface PBNativeDiffRenderer : NSObject
- (instancetype)initWithBaseAttributes:(NSDictionary<NSAttributedStringKey, id> *)baseAttributes
					titleAttributes:(NSDictionary<NSAttributedStringKey, id> *)titleAttributes
							parser:(PBDiffDocumentParser *)parser;
- (PBNativeRenderResult *)renderSections:(NSArray<PBNativeContentSection *> *)sections
						  collapsedFiles:(NSSet<NSString *> *)collapsedFiles
						  expandedImages:(NSSet<NSString *> *)expandedImages
					   imageDataProvider:(nullable NSData * (^)(NSString *path, NSInteger section, NSDictionary<NSString *, id> *imageSource))imageDataProvider;
@end

@protocol PBIndexCommandRunning <NSObject>
- (nullable NSString *)outputWithArguments:(NSArray<NSString *> *)arguments
										 input:(nullable NSString *)input
								 environment:(nullable NSDictionary<NSString *, id> *)environment
										 error:(NSError * _Nullable * _Nullable)error;
- (void)dataWithArguments:(NSArray<NSString *> *)arguments
                completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;
@end

@interface PBIndexRefreshResult : NSObject
@property (nonatomic, readonly, nullable) NSDictionary<NSString *, PBIndexStatusEntry *> *staged;
@property (nonatomic, readonly, nullable) NSDictionary<NSString *, PBIndexStatusEntry *> *unstaged;
@property (nonatomic, readonly, nullable) NSDictionary<NSString *, PBIndexStatusEntry *> *untracked;
@end

@interface PBIndexRefreshCoordinator : NSObject
- (instancetype)initWithRunner:(id<PBIndexCommandRunning>)runner
                         parser:(PBIndexStatusParser *)parser
                  statusHandler:(void (^)(BOOL success, NSString *message))statusHandler
                  resultHandler:(void (^)(PBIndexRefreshResult *result))resultHandler
                    idleHandler:(void (^)(void))idleHandler;
- (void)refreshBareRepository:(BOOL)bareRepository parentTree:(NSString *)parentTree;
- (void)refreshStatCacheForBareRepository:(BOOL)bareRepository completion:(void (^)(void))completion;
@end

@protocol PBIndexHookRunning <NSObject>
- (BOOL)executeHook:(NSString *)name
          arguments:(NSArray<NSString *> *)arguments
              error:(NSError * _Nullable * _Nullable)error;
@end

typedef NS_ENUM(NSInteger, PBIndexCommitResultKind) {
    PBIndexCommitResultKindSuccess,
    PBIndexCommitResultKindFailure,
    PBIndexCommitResultKindHookFailure,
};

@interface PBIndexCommitRequest : NSObject
- (instancetype)initWithMessage:(NSString *)message
                         verify:(BOOL)verify
                        gpgSign:(BOOL)gpgSign
                          amend:(BOOL)amend
                    environment:(nullable NSDictionary<NSString *, id> *)environment
                     parentSHAs:(NSArray<NSString *> *)parentSHAs
                        hasHead:(BOOL)hasHead;
@end

@interface PBIndexCommitResult : NSObject
@property (nonatomic, readonly) PBIndexCommitResultKind kind;
@property (nonatomic, readonly) NSString *message;
@property (nonatomic, readonly, nullable) NSString *sha;
@property (nonatomic, readonly) BOOL postCommitHookSucceeded;
@end

@interface PBIndexCommitService : NSObject
- (instancetype)initWithRunner:(id<PBIndexCommandRunning>)runner
                     hookRunner:(id<PBIndexHookRunning>)hookRunner
                   gitDirectory:(NSURL *)gitDirectory
             temporaryDirectory:(NSURL *)temporaryDirectory;
- (nullable NSString *)prepareCommitMessageForAmend:(BOOL)amend
                                            headSHA:(nullable NSString *)headSHA
                                    existingMessage:(nullable NSString *)existingMessage
                                              error:(NSError * _Nullable * _Nullable)error;
- (PBIndexCommitResult *)commitWithRequest:(PBIndexCommitRequest *)request
                                  progress:(void (^)(NSString *message))progress;
@end

@interface PBIndexMutationService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBIndexCommandRunning>)runner;
- (BOOL)stagePaths:(NSArray<NSString *> *)paths error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (BOOL)unstagePaths:(NSArray<NSString *> *)paths parentTree:(NSString *)parentTree error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (BOOL)discardPaths:(NSArray<NSString *> *)paths error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (BOOL)applyPatch:(NSString *)patch stage:(BOOL)stage reverse:(BOOL)reverse error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (nullable NSString *)diffForPath:(NSString *)path
							status:(NSInteger)status
				  hasStagedChanges:(BOOL)hasStagedChanges
							staged:(BOOL)staged
						parentTree:(NSString *)parentTree
					  contextLines:(NSUInteger)contextLines
							 error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
@end

@interface PBCommitRemotePresentation : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *remoteNames;
@property (nonatomic, copy, readonly, nullable) NSString *selectedRemoteName;
@property (nonatomic, readonly) BOOL canPush;
@end

@interface PBCommitRemotePresentationPolicy : NSObject
+ (NSArray<NSString *> *)sortedRemoteNames:(NSArray<NSString *> *)remoteNames
	NS_SWIFT_NAME(sortedRemoteNames(_:));
+ (BOOL)shouldResolveTrackingRemoteForRemoteNames:(NSArray<NSString *> *)remoteNames
								previousSelection:(nullable NSString *)previousSelection
										 isBranch:(BOOL)isBranch
	NS_SWIFT_NAME(shouldResolveTrackingRemote(remoteNames:previousSelection:isBranch:));
+ (PBCommitRemotePresentation *)presentationForRemoteNames:(NSArray<NSString *> *)remoteNames
										 previousSelection:(nullable NSString *)previousSelection
										trackingRemoteName:(nullable NSString *)trackingRemoteName
												  isBranch:(BOOL)isBranch
	NS_SWIFT_NAME(presentation(remoteNames:previousSelection:trackingRemoteName:isBranch:));
@end

typedef NS_ENUM(NSInteger, PBCommitSubmissionDisposition) {
	PBCommitSubmissionDispositionAccepted,
	PBCommitSubmissionDispositionMergeInProgress,
	PBCommitSubmissionDispositionNoStagedChanges,
	PBCommitSubmissionDispositionMessageTooShort,
};

@interface PBCommitSubmissionPlan : NSObject
@property (nonatomic, readonly) PBCommitSubmissionDisposition disposition;
@property (nonatomic, readonly) BOOL shouldArmPendingPush;
@end

@interface PBCommitSubmissionPolicy : NSObject
+ (PBCommitSubmissionPlan *)planForMergeInProgress:(BOOL)mergeInProgress
									   stagedCount:(NSInteger)stagedCount
									 messageLength:(NSInteger)messageLength
									   pushEnabled:(BOOL)pushEnabled
									 pushRequested:(BOOL)pushRequested
										  isBranch:(BOOL)isBranch
										remoteName:(nullable NSString *)remoteName
	NS_SWIFT_NAME(plan(mergeInProgress:stagedCount:messageLength:pushEnabled:pushRequested:isBranch:remoteName:));
@end

@interface PBCommitPushPlan : NSObject
@property (nonatomic, strong, readonly) PBGitRef *branchRef;
@property (nonatomic, copy, readonly) NSString *remoteName;
@end

@interface PBCommitWorkflowState : NSObject
@property (nonatomic, strong, nullable) PBGitRef *pendingBranchRef;
@property (nonatomic, copy, nullable) NSString *pendingRemoteName;
- (void)armWithBranchRef:(PBGitRef *)branchRef remoteName:(NSString *)remoteName
	NS_SWIFT_NAME(arm(branchRef:remoteName:));
- (void)clear;
- (nullable PBCommitPushPlan *)consumePendingPush;
@end

@interface PBCommitMessageResult : NSObject
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, readonly) BOOL didAddSignOff;
@end

@interface PBCommitMessagePolicy : NSObject
+ (PBCommitMessageResult *)messageByAddingSignOffToMessage:(NSString *)message
												  userName:(NSString *)userName
												 userEmail:(NSString *)userEmail
	NS_SWIFT_NAME(messageByAddingSignOff(to:userName:userEmail:));
+ (BOOL)shouldReplaceMessageForAmendWithCurrentMessage:(NSString *)currentMessage
	NS_SWIFT_NAME(shouldReplaceMessageForAmend(currentMessage:));
@end

@interface PBCommitSelectionPolicy : NSObject
+ (NSInteger)selectionIndexForCurrentIndex:(NSInteger)currentIndex arrangedCount:(NSInteger)arrangedCount
	NS_SWIFT_NAME(selectionIndex(currentIndex:arrangedCount:));
@end

@interface PBCommitMenuFile : NSObject
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, readonly) NSInteger status;
@property (nonatomic, readonly) BOOL hasUnstagedChanges;
- (instancetype)initWithPath:(NSString *)path
					  status:(NSInteger)status
		  hasUnstagedChanges:(BOOL)hasUnstagedChanges;
@end

@interface PBCommitMenuPresentation : NSObject
@property (nonatomic, copy, readonly, nullable) NSString *title;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL updatesHidden;
@property (nonatomic, readonly) BOOL hidden;
@property (nonatomic, readonly) BOOL updatesAlternate;
@property (nonatomic, readonly) BOOL alternate;
@property (nonatomic, readonly) BOOL updatesState;
@property (nonatomic, readonly) NSInteger state;
@end

@interface PBCommitMenuPresenter : NSObject
+ (PBCommitMenuPresentation *)presentationForAction:(SEL _Nullable)action
									  unstagedFiles:(NSArray<PBCommitMenuFile *> *)unstagedFiles
										stagedFiles:(NSArray<PBCommitMenuFile *> *)stagedFiles
									isStagedContext:(BOOL)isStagedContext
										allowsTrash:(BOOL)allowsTrash
								   isContextualMenu:(BOOL)isContextualMenu
						 singleSelectionIsSubmodule:(BOOL)singleSelectionIsSubmodule
											isAmend:(BOOL)isAmend
								  prepareHookExists:(BOOL)prepareHookExists
									fallbackEnabled:(BOOL)fallbackEnabled
	NS_SWIFT_NAME(presentation(action:unstagedFiles:stagedFiles:isStagedContext:allowsTrash:isContextualMenu:singleSelectionIsSubmodule:isAmend:prepareHookExists:fallbackEnabled:));
@end

@interface PBCommitList : NSTableView
@property (nonatomic) BOOL useAdjustScroll;
@property (nonatomic, readonly) NSPoint mouseDownPoint;
@end

extern NSString *PBGitRepositoryEventNotification;
extern NSString *kPBGitRepositoryEventTypeUserInfoKey;

@interface PBGitHistoryList : NSObject
@property (nonatomic, strong) NSMutableArray<PBGitCommit *> *commits;
@property (nonatomic, assign) BOOL isUpdating;
- (void)cleanup;
@end

@interface PBGitTree : NSObject
@property (nonatomic, readonly) BOOL leaf;
@property (nonatomic, readonly) NSArray<PBGitTree *> *children;
@property (nonatomic, readonly) NSString *contents;
@property (nonatomic, readonly) NSString *fullPath;
@property (nonatomic, readonly) NSString *displayPath;
- (long long)fileSize;
- (NSString *)textContents;
- (NSString *)blame;
- (NSString *)log:(NSString *)format;
- (NSString *)tmpFileNameForContents;
@end

@interface PBQLTextView : NSTextView
@end

@interface PBGitRevisionCell (GitXTests)
+ (NSColor *)shadowColor;
+ (NSColor *)lineShadowColor;
@end

@interface PBHistorySearchController (GitXTests)
- (BOOL)hasSearchResults;
@end

@interface PBHistoryTableInteractionCoordinator : NSObject <NSTableViewDelegate, NSTableViewDataSource>
@property (nonatomic) BOOL hasWorkingState;
- (nullable NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row;
- (NSIndexSet *)tableView:(NSTableView *)tableView
    selectionIndexesForProposedSelection:(NSIndexSet *)proposedSelectionIndexes;
- (BOOL)tableView:(NSTableView *)tableView
    writeRowsWithIndexes:(NSIndexSet *)rowIndexes
            toPasteboard:(NSPasteboard *)pasteboard;
- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)draggingInfo
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)operation;
- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)draggingInfo
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)operation;
- (void)didDoubleClickCommitList:(nullable id)sender;
@end

@interface PBGitHistoryController (GitXTests)
- (void)updateUncommittedChanges;
- (void)reselectCommitAfterUpdate;
- (void)updateKeys;
- (void)updateBranchFilterMatrix;
- (nullable PBGitCommit *)firstCommit;
- (void)updateStatus;
- (void)restoreFileBrowserSelection;
- (void)saveFileBrowserSelection;
- (void)historySortingPreferenceChanged:(NSNotification *)notification;
- (void)_repositoryUpdatedNotification:(NSNotification *)notification;
- (void)performFindPanelAction:(id)sender;
- (BOOL)isCommitSelected;
- (void)checkoutFiles:(id)sender;
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(nullable id)panel;
- (nullable id<QLPreviewItem>)previewPanel:(nullable id)panel previewItemAtIndex:(NSInteger)index;
- (BOOL)previewPanel:(nullable id)panel handleEvent:(NSEvent *)event;
- (NSRect)previewPanel:(nullable id)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item;
@end

NS_ASSUME_NONNULL_END

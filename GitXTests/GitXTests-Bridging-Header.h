#import <Quartz/Quartz.h>
#import "GitXRelativeDateFormatter.h"
#import "PBRepositoryFinder.h"
#import "PBMacros.h"
#import "PBGitRevSpecifier.h"
#import "PBGitDefaults.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitHistoryController.h"
#import "PBViewController.h"
#import "PBGitCommit.h"
#import "PBGitIndex.h"
#import "PBGitStash.h"
#import "PBUncommittedChanges.h"
#import "PBHighlighting.h"
#import "PBChangedFile.h"
#import "PBCommitMessageView.h"
#import "PBNativeContentView.h"
#import "PBTask.h"
#import "PBProcessEnvironment.h"
#import "PBGitRevisionCell.h"
#import "PBHistorySearchController.h"
#import "RepositoryIgnoreTestSupport.h"
#import "PBGitBinary.h"
#import "PBGitWindowControllerCompatibility.h"
#import "PBRepositoryDocumentControllerCompatibility.h"
#import "PBAutoFetchManagerCompatibility.h"
#import "PBWebHistoryControllerCompatibility.h"
#import "PBQLOutlineViewCompatibility.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBCommitRecoveryRepository : PBGitRepository
@property (nonatomic, copy, nullable) NSString *recoveryPatchOutput;
@property (nonatomic) NSUInteger recoveryPatchInvocationCount;
@end

@interface PBRepositoryOpenCoordinator : NSObject
@property (class, nonatomic, readonly) PBRepositoryOpenCoordinator *shared;
- (void)openURLs:(NSArray<NSURL *> *)urls
	sourceWindow:(nullable NSWindow *)sourceWindow
	  completion:(void (^)(NSArray<NSDocument *> *, NSArray<NSError *> *))completion;
@end

@interface PBGitBinary (HistoryFlowTestSupport)
+ (BOOL)acceptBinary:(nullable NSString *)path;
@end

@class PBHistoryFlowRevisionProviderTestOperation;

@interface PBHistoryFlowRevisionProviderTestOperation : NSObject
- (void)cancel;
@end

#if DEBUG
@interface PBHistoryFlowRevisionProviderTestHarness : NSObject
+ (NSString *)unsupportedPathDescription:(NSString *)path;
+ (NSDictionary<NSString *, id> *)drainPipeWithFileDescriptor:(int)descriptor NS_SWIFT_NAME(drainPipe(fileDescriptor:));
+ (PBHistoryFlowRevisionProviderTestOperation *)cancelledBeforeLaunchWithGitExecutableURL:(NSURL *)gitExecutableURL
																		completionHandler:(void (^)(NSString *_Nullable errorDescription))completionHandler
	NS_SWIFT_NAME(cancelledBeforeLaunch(gitExecutableURL:completionHandler:));
+ (PBHistoryFlowRevisionProviderTestOperation *)compareRepositoryAtURL:(NSURL *)repositoryURL
													  gitExecutableURL:(NSURL *)gitExecutableURL
																  base:(NSString *)base
																target:(NSString *)target
												   maximumChangedFiles:(NSInteger)maximumChangedFiles
													  maximumBlobBytes:(NSInteger)maximumBlobBytes
													 completionHandler:(void (^)(NSData *_Nullable data, NSString *_Nullable errorDescription))completionHandler;
@end
#endif

@interface PBChildProcessSupervisor : NSObject
- (instancetype)initWithLaunchPath:(NSString *)launchPath
						 arguments:(NSArray<NSString *> *)arguments
					   environment:(NSDictionary<NSString *, NSString *> *)environment
				  workingDirectory:(nullable NSString *)workingDirectory
	   standardInputFileDescriptor:(nullable NSNumber *)standardInputFileDescriptor
	  standardOutputFileDescriptor:(int)standardOutputFileDescriptor
	   standardErrorFileDescriptor:(nullable NSNumber *)standardErrorFileDescriptor
				terminationHandler:(void (^)(int status, NSError *_Nullable error))terminationHandler
	NS_SWIFT_NAME(init(launchPath:arguments:environment:workingDirectory:standardInputFileDescriptor:standardOutputFileDescriptor:standardErrorFileDescriptor:terminationHandler:));
- (BOOL)launchAndReturnError:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(launch());
- (void)requestTerminationAfterGracePeriod:(NSTimeInterval)gracePeriod forceKillAfter:(nullable NSNumber *)forceKillDelay NS_SWIFT_NAME(requestTermination(gracePeriod:forceKillDelay:));
@end

typedef NS_ENUM(NSInteger, PBOpenDisposition) {
	PBOpenDispositionAlwaysNewWindow,
	PBOpenDispositionFollowSystem,
	PBOpenDispositionPreferTab,
};

typedef NS_ENUM(NSInteger, PBWindowRestorePolicy) {
	PBWindowRestorePolicyAlways,
	PBWindowRestorePolicyFollowSystem,
	PBWindowRestorePolicyNever,
};

typedef NS_ENUM(NSInteger, PBDiffLayout) {
	PBDiffLayoutUnified,
	PBDiffLayoutSideBySide,
};

typedef NS_ENUM(NSInteger, PBDiffAlgorithm) {
	PBDiffAlgorithmMyers,
	PBDiffAlgorithmMinimal,
	PBDiffAlgorithmPatience,
	PBDiffAlgorithmHistogram,
};

typedef NS_ENUM(NSInteger, PBSyntaxTheme) {
	PBSyntaxThemeXcode,
	PBSyntaxThemeGithub,
	PBSyntaxThemePlain,
};

typedef NS_ENUM(NSInteger, PBBranchSortMode) {
	PBBranchSortModeAlphabetical,
	PBBranchSortModeRecentCommit,
};

typedef NS_ENUM(NSInteger, PBHistorySearchExecutionKind) {
	PBHistorySearchExecutionKindClear,
	PBHistorySearchExecutionKindBasic,
	PBHistorySearchExecutionKindBackground,
};

@interface PBHistorySearchPlan : NSObject
@property (nonatomic, readonly) PBHistorySearchExecutionKind kind;
@property (nonatomic, copy, readonly) NSString *query;
@property (nonatomic, copy, readonly) NSArray<NSString *> *arguments;
@end

@interface PBHistorySearchPolicy : NSObject
+ (PBHistorySearchPlan *)planForQuery:(NSString *)query
							 mode:(NSInteger)mode NS_SWIFT_NAME(plan(query:mode:));
@end

typedef NS_ENUM(NSInteger, PBChangedFilesSortMode) {
	PBChangedFilesSortModeAlphabetical,
	PBChangedFilesSortModeGitOrder,
	PBChangedFilesSortModeStatus,
};

typedef NS_ENUM(NSInteger, PBStagingListLayout) {
	PBStagingListLayoutSectionedList,
	PBStagingListLayoutSplitTables,
};

typedef NS_ENUM(NSInteger, PBStagingFileSortOrder) {
	PBStagingFileSortOrderPath,
	PBStagingFileSortOrderStatus,
};

typedef NS_ENUM(NSInteger, PBApplicationIconStyle) {
	PBApplicationIconStylePlusEyes,
	PBApplicationIconStyleBracketed,
	PBApplicationIconStyleCursor,
	PBApplicationIconStyleMixedDiff,
};

@interface PBApplicationPreferences : NSObject
@property (nonatomic, readonly, strong) NSUserDefaults *userDefaults;
- (void)registerDefaults:(NSDictionary<NSString *, id> *)defaults NS_SWIFT_NAME(registerDefaults(_:));
- (nullable id)objectForKey:(NSString *)key NS_SWIFT_NAME(object(forKey:));
- (nullable NSString *)stringForKey:(NSString *)key NS_SWIFT_NAME(string(forKey:));
- (nullable NSArray *)arrayForKey:(NSString *)key NS_SWIFT_NAME(array(forKey:));
- (nullable NSDictionary<NSString *, id> *)dictionaryForKey:(NSString *)key NS_SWIFT_NAME(dictionary(forKey:));
- (nullable NSData *)dataForKey:(NSString *)key NS_SWIFT_NAME(data(forKey:));
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key NS_SWIFT_NAME(integer(forKey:));
- (double)doubleForKey:(NSString *)key NS_SWIFT_NAME(double(forKey:));
- (void)setObject:(nullable id)value forKey:(NSString *)key NS_SWIFT_NAME(setObject(_:forKey:));
- (void)setBool:(BOOL)value forKey:(NSString *)key NS_SWIFT_NAME(setBool(_:forKey:));
- (void)setInteger:(NSInteger)value forKey:(NSString *)key NS_SWIFT_NAME(setInteger(_:forKey:));
- (void)setDouble:(double)value forKey:(NSString *)key NS_SWIFT_NAME(setDouble(_:forKey:));
- (void)removeObjectForKey:(NSString *)key NS_SWIFT_NAME(removeObject(forKey:));
- (void)synchronize;
@end

@interface PBApplicationComposition : NSObject
@property (nonatomic, readonly, strong) PBApplicationPreferences *applicationPreferences;
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults;
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults
	automaticallyStartsForgeServices:(BOOL)automaticallyStartsForgeServices;
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults
		 forgeStartupFailureProvider:(void (^)(void (^completionHandler)(NSError *)))failureProvider
	automaticallyStartsForgeServices:(BOOL)automaticallyStartsForgeServices
	NS_SWIFT_NAME(init(userDefaults:forgeStartupFailureProvider:automaticallyStartsForgeServices:));
- (void)waitForAutomaticForgeServiceStartupForTestingWithCompletionHandler:(void (^)(void))completionHandler
	NS_SWIFT_NAME(waitForAutomaticForgeServiceStartupForTesting(completionHandler:));
- (void)retryForgeServicesForTestingWithCompletionHandler:(void (^)(NSError *_Nullable))completionHandler
	NS_SWIFT_NAME(retryForgeServicesForTesting(completionHandler:));
+ (PBApplicationComposition *)sharedComposition;
+ (void)setSharedComposition:(PBApplicationComposition *)composition;
@end

@interface PBApplicationSettings : NSObject
@property (class) BOOL repositoryStatusBarVisible;
@property (class) PBOpenDisposition openDisposition;
@property (class) PBWindowRestorePolicy restorePolicy;
@property (class) BOOL changedFilesOnly;
@property (class) PBChangedFilesSortMode changedFilesSort;
@property (class) BOOL groupIncomingBranchCommits;
@property (class) PBBranchSortMode branchSort;
@property (class) PBDiffLayout diffLayout;
@property (class) PBDiffAlgorithm diffAlgorithm;
@property (class) NSInteger diffContextLines;
@property (class) PBSyntaxTheme syntaxTheme;
@property (class, copy) NSString *diffFontName;
@property (class) double diffFontSize;
@property (class, strong) NSColor *addedTextColor;
@property (class, strong) NSColor *removedTextColor;
@property (class, strong) NSColor *addedBackgroundColor;
@property (class, strong) NSColor *removedBackgroundColor;
@property (class, copy, nullable) NSString *terminalBundleIdentifier;
@property (class, copy) NSString *terminalInitialCommand;
@property (class, copy) NSString *customTerminalExecutable;
@property (class, copy) NSString *customTerminalArguments;
@property (class, copy) NSString *raycastScriptsDirectory;
@property (class) NSInteger patchExportMode;
@property (class) PBApplicationIconStyle applicationIconStyle;
@property (class) PBStagingListLayout stagingListLayout;
@property (class) PBStagingFileSortOrder stagingFileSortOrder;
@property (class) BOOL loadAvatars;
@property (class, copy) NSString *attentionPollingPresetRawValue;
@property (class, copy) NSArray<NSString *> *attentionAlertCategoryRawValues;
@property (class) BOOL attentionIncludesFailedChecksOnAuthoredPullRequests;
@property (class) BOOL attentionIncludesFailedChecksAwaitingReview;
@property (class, copy, nullable) NSData *attentionViewStateData;
@end

typedef NS_ENUM(NSInteger, PBStagingListSection) {
	PBStagingListSectionStaged,
	PBStagingListSectionUnstaged,
};

typedef NS_ENUM(NSInteger, PBStagingFileAction) {
	PBStagingFileActionStage,
	PBStagingFileActionUnstage,
	PBStagingFileActionDiscard,
	PBStagingFileActionForceDiscard,
	PBStagingFileActionOpen,
	PBStagingFileActionReveal,
	PBStagingFileActionIgnore,
	PBStagingFileActionTrash,
};

typedef NS_ENUM(NSInteger, PBStagingSelectionContext) {
	PBStagingSelectionContextSectioned,
	PBStagingSelectionContextSplitStaged,
	PBStagingSelectionContextSplitUnstaged,
	PBStagingSelectionContextSplitAutomatic,
};

@interface PBStagingActionSelection : NSObject
- (instancetype)initWithAction:(PBStagingFileAction)action files:(NSArray<PBChangedFile *> *)files;
@property (nonatomic, readonly) PBStagingFileAction action;
@property (nonatomic, readonly) NSArray<PBChangedFile *> *files;
@end

@interface PBStagingListRow : NSObject
@property (nonatomic, readonly) BOOL isHeader;
@property (nonatomic, readonly) PBStagingListSection section;
@property (nonatomic, readonly, nullable) PBChangedFile *file;
@end

@interface PBStagingDiffRequest : NSObject
- (instancetype)initWithFile:(PBChangedFile *)file staged:(BOOL)staged;
@property (nonatomic, readonly) PBChangedFile *file;
@property (nonatomic, readonly) BOOL staged;
@end

@class PBStagingDiffRequest;
@protocol PBIndexCommandRunning;

@interface PBStagingDiffPaneController : NSObject
@property (nonatomic, readonly) PBNativeContentView *contentView;
@property (nonatomic) NSUInteger contextLines;
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (instancetype)initWithRepository:(PBGitRepository *)repository
				 diffRunner:(nullable id<PBIndexCommandRunning>)diffRunner;
- (void)renderRequests:(NSArray<PBStagingDiffRequest *> *)requests;
- (void)rerenderCurrentRequests;
@end

@class PBStagingListViewModel;

@interface PBStagingFileCellView : NSTableCellView
@property (nonatomic, readonly) NSButton *checkbox;
@property (nonatomic, readonly) NSTextField *pathField;
@property (nonatomic, readonly) NSButton *overflowButton;
- (void)configureWithFile:(PBChangedFile *)file checkboxState:(NSInteger)checkboxState
	NS_SWIFT_NAME(configure(with:checkboxState:));
- (void)configureWithFile:(PBChangedFile *)file checkboxState:(NSInteger)checkboxState section:(PBStagingListSection)section NS_SWIFT_NAME(configure(with:checkboxState:section:));
@end

@interface PBStagingSectionHeaderView : NSView
@property (nonatomic, readonly) NSButton *masterCheckbox;
- (void)configureWithTitle:(NSString *)title fileCount:(NSInteger)fileCount masterState:(NSInteger)masterState
	NS_SWIFT_NAME(configure(title:fileCount:masterState:));
@end

@interface PBCommitTableInteractionCoordinator : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository index:(PBGitIndex *)index unstagedFilesController:(NSArrayController *)unstagedFilesController stagedFilesController:(NSArrayController *)stagedFilesController unstagedTable:(NSTableView *)unstagedTable stagedTable:(NSTableView *)stagedTable;
- (void)stageSelectedFiles;
- (void)unstageSelectedFiles;
- (void)toggleStagingForTableView:(NSTableView *)tableView;
- (void)focusTable:(NSTableView *)tableView;
- (BOOL)handleCommandSelector:(SEL)commandSelector;
- (void)displayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row inTableView:(NSTableView *)tableView;
- (void)didDoubleClickTableView:(NSTableView *)tableView;
- (BOOL)writeRowsWithIndexes:(NSIndexSet *)rowIndexes fromTableView:(NSTableView *)tableView toPasteboard:(NSPasteboard *)pasteboard;
- (NSDragOperation)validateDrop:(id<NSDraggingInfo>)info inTableView:(NSTableView *)tableView;
- (BOOL)acceptDrop:(id<NSDraggingInfo>)info inTableView:(NSTableView *)tableView;
@end

@interface PBStagingFileListController : NSObject
@property (nonatomic, readonly) PBCommitTableInteractionCoordinator *interactionCoordinator;
@property (nonatomic, readonly) PBStagingListViewModel *viewModel;
@property (nonatomic, readonly) NSArrayController *unstagedFilesController;
@property (nonatomic, readonly) NSArrayController *stagedFilesController;
@property (nonatomic, readonly) NSTableView *unstagedTable;
@property (nonatomic, readonly) NSTableView *stagedTable;
@property (nonatomic, readonly) NSTableView *sectionedTable;
@property (nonatomic, readonly) PBStagingListLayout layout;
@property (nonatomic, readonly) NSInteger stagedFileCount;
- (void)applyFilterAndSort;
- (void)rearrange;
- (void)setListLayout:(PBStagingListLayout)layout;
- (NSArray<PBChangedFile *> *)selectedFilesForStagedContext:(BOOL)stagedContext;
- (PBStagingActionSelection *)resolvedSelectionForAction:(PBStagingFileAction)action
								  contextualMenu:(nullable NSMenu *)contextualMenu;
@end

@interface PBCommitMessageTransformer : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (nullable NSString *)transformMessage:(NSString *)message error:(NSError *_Nullable *_Nullable)error;
@end

@interface PBStagingViewController : NSViewController
@property (nonatomic, copy) BOOL (^trashItemHandler)(NSURL *);
@property (nonatomic, readonly) PBStagingFileListController *fileListController;
@property (nonatomic, readonly) PBStagingDiffPaneController *diffPaneController;
@property (nonatomic, readonly) PBCommitMessageView *commitMessageView;
@property (nonatomic, readonly) NSSearchField *searchField;
@property (nonatomic, readonly) NSResponder *paneFirstResponder;
- (void)updateView;
- (void)closeView;
- (void)reloadPushRemotes;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

@interface PBStagingListViewModel : NSObject
@property (nonatomic, readonly) NSUInteger sortPassCount;
@property (nonatomic, readonly, copy) NSArray<NSSortDescriptor *> *sortDescriptors;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic) PBStagingFileSortOrder sortOrder;
- (NSArray<PBChangedFile *> *)filesInSection:(PBStagingListSection)section
								 fromChanges:(NSArray<PBChangedFile *> *)changes;
- (NSArray<PBStagingListRow *> *)flattenedRowsFromChanges:(NSArray<PBChangedFile *> *)changes;
- (NSInteger)stagedFileCountFromChanges:(NSArray<PBChangedFile *> *)changes;
- (NSArray<PBChangedFile *> *)resolvedFilesForAction:(PBStagingFileAction)action
									 context:(PBStagingSelectionContext)context
							 stagedSelection:(NSArray<PBChangedFile *> *)stagedSelection
						   unstagedSelection:(NSArray<PBChangedFile *> *)unstagedSelection;
- (NSArray<NSDictionary<NSString *, id> *> *)sectionedDragPayloadForRows:(NSArray<PBStagingListRow *> *)rows
												 selectedIndexes:(NSIndexSet *)selectedIndexes;
- (nullable NSArray<PBChangedFile *> *)resolvedDropFilesFromPropertyList:(nullable id)propertyList
														 rows:(NSArray<PBStagingListRow *> *)rows
											  destinationSection:(PBStagingListSection)destinationSection;
- (NSInteger)rowCheckboxStateForFile:(PBChangedFile *)file inSection:(PBStagingListSection)section;
- (NSInteger)masterCheckboxStateForChanges:(NSArray<PBChangedFile *> *)changes
								 inSection:(PBStagingListSection)section;
- (NSArray<PBStagingDiffRequest *> *)diffRequestsForStagedSelection:(NSArray<PBChangedFile *> *)stagedSelection
												   unstagedSelection:(NSArray<PBChangedFile *> *)unstagedSelection;
- (NSArray<PBStagingDiffRequest *> *)diffRequestsForRows:(NSArray<PBStagingListRow *> *)rows
										 selectedIndexes:(NSIndexSet *)selectedIndexes;
@end

@interface PBNativeContentTypography : NSObject
- (instancetype)initWithFontName:(NSString *)fontName baseSize:(CGFloat)baseSize;
- (NSAttributedString *)restyledString:(NSAttributedString *)attributedString;
@end

@interface PBApplicationIconController : NSObject
+ (NSImage *)imageForStyle:(PBApplicationIconStyle)style NS_SWIFT_NAME(image(for:));
+ (void)applySelectedIcon;
@end

@interface PBHistoryTreePresentation : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (PBGitTree *)treeForCommit:(PBGitCommit *)commit;
- (NSString *)displayTitleForTree:(PBGitTree *)tree;
- (NSString *)toolTipForTree:(PBGitTree *)tree;
@end

@interface PBDiffCommandOptions : NSObject
@property (class, copy, readonly) NSArray<NSString *> *arguments;
@end

@interface PBSettingsViewFactory : NSObject
+ (NSView *)generalViewWithLegacyView:(NSView *)legacyView NS_SWIFT_NAME(generalView(legacyView:));
+ (NSView *)dockIconView;
+ (NSView *)windowsView;
+ (NSView *)diffAndTextView;
+ (NSView *)terminalView;
@end

@interface PBForgeMarkdownAvatarProductHarness : NSObject
+ (uint64_t)markdownProof;
+ (uint64_t)requestProof;
+ (BOOL)validateAvatarData:(NSData *)data
         declaredMediaType:(NSString *)declaredMediaType
             maximumPixels:(NSInteger)maximumPixels
             expectedWidth:(NSInteger)expectedWidth
            expectedHeight:(NSInteger)expectedHeight;
+ (uint64_t)avatarFallbackProof;
+ (void)loaderProofWithCompletion:(void (^)(uint64_t proof))completion
	NS_SWIFT_NAME(loaderProof(completion:));
+ (void)sidebarAttentionProofWithCompletion:(void (^)(uint64_t proof))completion
	NS_SWIFT_NAME(sidebarAttentionProof(completion:));
+ (void)windowRecoveryProofWithCompletion:(void (^)(uint64_t proof))completion
	NS_SWIFT_NAME(windowRecoveryProof(completion:));
+ (void)applicationStartupFailureProofWithCompletion:(void (^)(uint64_t proof))completion
	NS_SWIFT_NAME(applicationStartupFailureProof(completion:));
+ (void)collaborationLifecycleProofWithCompletion:(void (^)(uint64_t proof))completion
	NS_SWIFT_NAME(collaborationLifecycleProof(completion:));
@end

@interface PBTerminalLauncher : NSObject
@property (class, readonly, strong) PBTerminalLauncher *shared;
- (void)openDirectory:(NSURL *)directory presentingWindow:(nullable NSWindow *)window
	NS_SWIFT_NAME(open(directory:presenting:));
- (NSArray<NSString *> *)launchArgumentsForIdentifier:(NSString *)identifier
										  directory:(NSString *)directory
											command:(NSString *)command
	NS_SWIFT_NAME(launchArguments(identifier:directory:command:));
- (NSArray<NSString *> *)argumentTokens:(NSString *)string;
- (NSArray<NSString *> *)customArgumentsForTemplate:(NSString *)template
                                           directory:(NSString *)directory
                                             command:(NSString *)command
	NS_SWIFT_NAME(customArguments(template:directory:command:));
- (void)completeApplicationLaunchWithError:(nullable NSError *)error
                          presentingWindow:(nullable NSWindow *)window
	NS_SWIFT_NAME(completeApplicationLaunch(error:presenting:));
@end

@interface PBRepositoryIgnoreFileService : NSObject
- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (instancetype)initWithFileURL:(NSURL *)fileURL
				fileCoordinator:(NSFileCoordinator *)fileCoordinator;
- (BOOL)appendPaths:(NSArray<NSString *> *)paths
              error:(NSError * _Nullable * _Nullable)error;
@end

@interface PBIntegrationManager : NSObject
@property (class, readonly, strong) PBIntegrationManager *shared;
- (void)installRaycastScriptsWithPresenting:(nullable NSWindow *)window
	NS_SWIFT_NAME(installRaycastScripts(presenting:));
- (void)removeRaycastScriptsWithPresenting:(nullable NSWindow *)window
	NS_SWIFT_NAME(removeRaycastScripts(presenting:));
@end

@interface PBManagedScriptChecksumPolicy : NSObject
+ (NSString *)managedScriptForBody:(NSString *)body NS_SWIFT_NAME(managedScript(for:));
+ (BOOL)hasValidChecksumForScript:(NSString *)script NS_SWIFT_NAME(hasValidChecksum(for:));
@end

@interface PBRaycastScriptCatalog : NSObject
+ (NSDictionary<NSString *, NSString *> *)scriptContentsForApplicationPath:(NSString *)applicationPath
	NS_SWIFT_NAME(scriptContents(forApplicationPath:));
+ (NSString *)shellQuotedValue:(NSString *)value NS_SWIFT_NAME(shellQuoted(_:));
@end

@interface PBRecentRepositoryStore : NSObject
@property (class, readonly, strong) PBRecentRepositoryStore *shared;
- (void)record:(NSURL *)url;
- (void)remove:(NSURL *)url;
- (void)replace:(NSURL *)oldURL with:(NSURL *)newURL;
@end

@interface PBCommitPatchExportPolicy : NSObject
+ (NSArray<NSString *> *)filenamesForSubjects:(NSArray<NSString *> *)subjects;
+ (NSString *)safeFilenameForSubject:(NSString *)subject;
+ (NSString *)revisionForOldestSHA:(NSString *)oldestSHA
						 newestSHA:(NSString *)newestSHA
					oldestIsRoot:(BOOL)oldestIsRoot;
+ (BOOL)seriesOutput:(NSString *)output
         matchesSHAs:(NSArray<NSString *> *)shas
    NS_SWIFT_NAME(series(output:matchesSHAs:));
@end

@interface PBHistoryBranchFilterPresentation : NSObject
@property (nonatomic, readonly) BOOL allEnabled;
@property (nonatomic, readonly) BOOL localEnabled;
@property (nonatomic, readonly) NSControlStateValue allState;
@property (nonatomic, readonly) NSControlStateValue localState;
@property (nonatomic, readonly) NSControlStateValue selectedState;
@property (nonatomic, copy, readonly) NSString *selectedTitle;
@property (nonatomic, copy, readonly) NSString *localTitle;
@end

typedef NS_ENUM(NSInteger, PBHistoryDetailMode) {
	PBHistoryDetailModeDetails = 0,
	PBHistoryDetailModeTree = 1,
	PBHistoryDetailModeFlow = 2,
} NS_SWIFT_NAME(HistoryDetailMode);

@interface PBHistoryStateCoordinator : NSObject
- (NSArray<PBGitCommit *> *)normalizedSelection:(NSArray<PBGitCommit *> *)selection;
- (PBHistoryDetailMode)detailModeForPersistedIndex:(NSInteger)persistedIndex
	NS_SWIFT_NAME(detailMode(persistedIndex:));
- (PBHistoryDetailMode)detailModeForCurrentMode:(PBHistoryDetailMode)current
                                 selectionCount:(NSInteger)selectionCount
	NS_SWIFT_NAME(detailMode(current:selectionCount:));
- (BOOL)shouldShowStagingForSelection:(NSArray<PBGitCommit *> *)selection
	NS_SWIFT_NAME(shouldShowStaging(for:));
- (nullable NSArray<PBGitCommit *> *)preservedSelection:(NSArray<PBGitCommit *> *)selection
                                              inContent:(NSArray<PBGitCommit *> *)content;
- (PBHistoryBranchFilterPresentation *)branchFilterPresentationForSimpleBranch:(BOOL)simpleBranch
																			 filter:(NSInteger)filter
															 selectedTitle:(NSString *)selectedTitle
																			 remote:(BOOL)remote
	NS_SWIFT_NAME(branchFilterPresentation(simpleBranch:filter:selectedTitle:remote:));
- (void)saveFileBrowserSelectionFromSelectedObjects:(NSArray<NSObject *> *)selectedObjects
																	 hasContent:(BOOL)hasContent
	NS_SWIFT_NAME(saveFileBrowserSelection(selectedObjects:hasContent:));
- (nullable NSIndexPath *)treeSelectionIndexPathForChildren:(NSArray<NSObject *> *)children
																			 treeMode:(BOOL)treeMode
	NS_SWIFT_NAME(treeSelectionIndexPath(children:treeMode:));
- (NSInteger)adjustedScrollRowForSelectionRow:(NSInteger)selectionRow
													 oldRow:(NSInteger)oldRow
											 visibleRows:(NSInteger)visibleRows
											contentCount:(NSInteger)contentCount
	NS_SWIFT_NAME(adjustedScrollRow(selectionRow:oldRow:visibleRows:contentCount:));
@end

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

@interface PBPerformanceBudgets : NSObject
@property (class, nonatomic, readonly) double mainThreadBlockSeconds;
@property (class, nonatomic, readonly) double cachedWorkingStateFeedbackSeconds;
@property (class, nonatomic, readonly) double freshWorkingStateP95Seconds;
@property (class, nonatomic, readonly) NSInteger representativeChangedFileCount;
@property (class, nonatomic, readonly) NSInteger representativeDiffByteCount;
@property (class, nonatomic, readonly) NSInteger stressChangedFileCount;
@property (class, nonatomic, readonly) NSInteger stressDiffByteCount;
@end

typedef NS_ENUM(NSInteger, PBRecentRepositoryActivationAction) {
	PBRecentRepositoryActivationActionOpen,
	PBRecentRepositoryActivationActionLocate,
};

@interface PBRecentRepositoryActivationPolicy : NSObject
+ (PBRecentRepositoryActivationAction)actionForReachable:(BOOL)reachable
	NS_SWIFT_NAME(action(forReachable:));
@end

@interface PBRecentRepositoryKeyNavigation : NSObject
+ (NSInteger)nextRowFromRow:(NSInteger)currentRow
                   rowCount:(NSInteger)rowCount
                 movingDown:(BOOL)movingDown
	NS_SWIFT_NAME(nextRow(fromRow:rowCount:movingDown:));
@end

@interface PBTerminalUtil : NSObject
+ (NSString *)shellQuote:(NSString *)string;
@end

@interface PBRewindOverlayView : NSView
- (instancetype)initWithFrame:(NSRect)frameRect;
@end

@interface PBRepositoryRemoteURLCoordinator : NSObject
@property (class, nonatomic, readonly) PBRepositoryRemoteURLCoordinator *shared;
- (nullable NSURL *)firstHTTPURLInOutput:(NSString *)output NS_SWIFT_NAME(firstHTTPURL(in:));
@end

@interface PBTaskDiagnostics : NSObject
+ (NSString *)redacted:(nullable id)text;
+ (NSString *)displayArguments:(NSArray *)arguments;
@end

@interface PBErrorMessagePresentation : NSObject
+ (NSString *)infoTextForError:(NSError *)error NS_SWIFT_NAME(infoText(for:));
@end

@interface PBTaskDiagnosticPrefix : NSObject
@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) BOOL complete;
@end

@interface PBTaskDiagnosticArtifact : NSObject
@property (nonatomic, readonly) NSString *redactedSummary;
@property (nonatomic, readonly) BOOL captureComplete;
@property (nonatomic, readonly, nullable) NSString *captureFailureDescription;
- (PBTaskDiagnosticPrefix *)rawStandardOutputPrefixWithMaximumBytes:(NSInteger)maximumBytes NS_SWIFT_NAME(rawStandardOutputPrefix(maximumBytes:));
- (void)forEachRawStandardErrorLineWithMaximumLineBytes:(NSInteger)maximumLineBytes body:(void (^)(NSString *line))body NS_SWIFT_NAME(forEachRawStandardErrorLine(maximumLineBytes:body:));
- (nullable NSString *)firstRawStandardErrorLineWithMaximumLineBytes:(NSInteger)maximumLineBytes matching:(BOOL (^)(NSString *line))body NS_SWIFT_NAME(firstRawStandardErrorLine(maximumLineBytes:matching:));
- (BOOL)writeRedactedReportToURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(writeRedactedReport(to:));
- (void)discard;
@end

#if DEBUG
@interface PBPushOutputExportCoordinatorTestHarness : NSObject
+ (nullable PBTaskDiagnosticArtifact *)artifactForError:(NSError *)error NS_SWIFT_NAME(artifact(for:));
+ (nullable NSButton *)buttonForError:(NSError *)error NS_SWIFT_NAME(button(for:));
+ (void)installOnWindow:(nullable NSWindow *)window error:(NSError *)error NS_SWIFT_NAME(install(on:error:));
+ (void)exportProofForScenario:(NSString *)scenario completion:(void (^)(NSDictionary<NSString *, NSNumber *> *facts))completion NS_SWIFT_NAME(exportProof(scenario:completion:));
@end
#endif

@interface PBTaskDiagnosticCapture : NSObject
@property (nonatomic, readonly, nullable) PBTaskDiagnosticArtifact *artifact;
- (void)appendStandardOutput:(NSData *)data;
- (void)appendStandardError:(NSData *)data;
- (void)finishStandardOutputWithReachedEOF:(BOOL)reachedEOF NS_SWIFT_NAME(finishStandardOutput(reachedEOF:));
- (void)finishStandardErrorWithReachedEOF:(BOOL)reachedEOF NS_SWIFT_NAME(finishStandardError(reachedEOF:));
- (PBTaskDiagnosticArtifact *)seal;
+ (void)cleanupStaleCaptures;
@end

#if DEBUG
@interface PBTaskDiagnosticCaptureLifetimeProbe : NSObject
@property (nonatomic, readonly) BOOL directoryExists;
@property (nonatomic, readonly) NSUInteger directoryMode;
@property (nonatomic, readonly) NSArray<NSNumber *> *rawFileModes;
@property (nonatomic, readonly) BOOL writerDescriptorsAreCloseOnExec;
@property (nonatomic, readonly) BOOL writersClosed;
- (BOOL)markStaleForCleanupAndReturnError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(markStaleForCleanup());
- (void)discardFixture;
@end

@interface PBTaskDiagnosticCaptureTestHarness : NSObject
+ (PBTaskDiagnosticCapture *)captureWithFault:(NSString *)fault NS_SWIFT_NAME(capture(fault:));
+ (nullable PBTaskDiagnosticCaptureLifetimeProbe *)lifetimeProbeForCapture:(PBTaskDiagnosticCapture *)capture NS_SWIFT_NAME(lifetimeProbe(for:));
+ (nullable PBTaskDiagnosticCaptureLifetimeProbe *)orphanProbeWithAge:(NSTimeInterval)age error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(orphanProbe(age:));
+ (nullable PBTaskDiagnosticCaptureLifetimeProbe *)unlockedLeasedOrphanProbeWithAge:(NSTimeInterval)age error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(unlockedLeasedOrphanProbe(age:));
@end
#endif

@interface PBRepositoryPushCommandResult : NSObject
@property (nonatomic, copy, readonly) NSString *standardOutput;
@property (nonatomic, copy, readonly) NSString *standardError;
@property (nonatomic, readonly) BOOL standardOutputComplete;
@property (nonatomic, readonly) BOOL standardErrorComplete;
@property (nonatomic, strong, readonly, nullable) PBTaskDiagnosticArtifact *diagnosticArtifact;
@property (nonatomic, copy, readonly) NSString *browserHintOutput;
@property (nonatomic, strong, readonly, nullable) NSNumber *terminationStatus;
@property (nonatomic, strong, readonly, nullable) NSError *error;
- (instancetype)initWithStandardOutput:(NSString *)standardOutput standardError:(NSString *)standardError terminationStatus:(nullable NSNumber *)terminationStatus error:(nullable NSError *)error;
- (instancetype)initWithStandardOutput:(NSString *)standardOutput standardError:(NSString *)standardError terminationStatus:(nullable NSNumber *)terminationStatus error:(nullable NSError *)error standardOutputComplete:(BOOL)standardOutputComplete standardErrorComplete:(BOOL)standardErrorComplete diagnosticArtifact:(nullable PBTaskDiagnosticArtifact *)diagnosticArtifact browserHintOutput:(NSString *)browserHintOutput;
@end

@protocol PBGitCommandRunning <NSObject>
- (NSString * _Nullable)historyOutputWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
- (PBRepositoryPushCommandResult *)pushWithArguments:(NSArray<NSString *> *)arguments;
- (nullable NSString *)outputWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
- (BOOL)launchWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
@end

@protocol PBGitEvidenceCommandRunning <PBGitCommandRunning>
@property (nonatomic, copy, readonly) NSString *evidenceExecutableIdentity;
- (nullable NSData *)evidenceDataWithArguments:(NSArray<NSString *> *)arguments inputData:(nullable NSData *)inputData environment:(nullable NSDictionary<NSString *, NSString *> *)environment error:(NSError * _Nullable * _Nullable)error;
@end

@interface PBRepositoryReferenceStore : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (nullable PBGitRef *)refForName:(nullable NSString *)name;
- (BOOL)isOID:(nullable GTOID *)branchOID onSameBranchAsOID:(nullable GTOID *)testOID commits:(nullable NSArray<PBGitCommit *> *)commits NS_SWIFT_NAME(isOID(_:onSameBranchAs:commits:));
@end

#if DEBUG
@interface PBMilestone2ProductCoverageHarness (ReviewFixProof)
+ (uint64_t)rejectedPushRecoveryProof;
+ (void)reviewRetryCancellationWorkflowWithCompletion:(void (^)(BOOL preservedAndReusable))completion NS_SWIFT_NAME(reviewRetryCancellationWorkflow(completion:));
+ (uint64_t)verificationBoundaryProof;
+ (nullable NSString *)reviewHistoryOutputWithRepository:(PBGitRepository *)repository arguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(reviewHistoryOutput(repository:arguments:));
+ (PBRepositoryPushCommandResult *)reviewPushCommandResultWithRepository:(PBGitRepository *)repository arguments:(NSArray<NSString *> *)arguments NS_SWIFT_NAME(reviewPushCommandResult(repository:arguments:));
+ (PBRepositoryPushCommandResult *)reviewPushCommandResultWithRepository:(PBGitRepository *)repository arguments:(NSArray<NSString *> *)arguments captureFault:(NSString *)captureFault NS_SWIFT_NAME(reviewPushCommandResult(repository:arguments:captureFault:));
+ (uint64_t)reviewPushRepeatedCallbacksProof;
+ (nullable NSString *)reviewGeneralOutputWithRepository:(PBGitRepository *)repository arguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(reviewGeneralOutput(repository:arguments:));
+ (BOOL)reviewGeneralLaunchWithRepository:(PBGitRepository *)repository arguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(reviewGeneralLaunch(repository:arguments:));
+ (NSString *)reviewEvidenceExecutableIdentityWithRepository:(PBGitRepository *)repository NS_SWIFT_NAME(reviewEvidenceExecutableIdentity(repository:));
+ (NSWindow *)reviewPushFailureWindowWithError:(NSError *)error NS_SWIFT_NAME(reviewPushFailureWindow(error:));
+ (NSAlert *)reviewSuppressionAlertWithIdentifier:(BOOL)hasIdentifier allowsSuppression:(BOOL)allowsSuppression NS_SWIFT_NAME(reviewSuppressionAlert(hasIdentifier:allowsSuppression:));
@end
#endif

@interface PBRepositoryPushRetryPlan : NSObject
@property (nonatomic, readonly, copy) NSString *branchName;
@property (nonatomic, readonly, copy) NSString *remoteName;
@property (nonatomic, readonly, copy) NSString *sourceOID;
@property (nonatomic, readonly, copy) NSString *fetchedOID;
@property (nonatomic, readonly, copy) NSString *destinationRef;
@property (nonatomic, readonly, copy) NSString *endpoint;
+ (nullable instancetype)planForError:(NSError *)error NS_SWIFT_NAME(plan(forError:));
@end

@interface PBRepositoryRemoteService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
@property (nonatomic, readonly) BOOL commandWasLaunched;
@property (nonatomic, copy, readonly, nullable) NSString *lastPushOutput;
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (nullable NSArray<NSString *> *)remotes;
- (BOOL)addRemote:(NSString *)remoteName withURL:(NSString *)URLString error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)fetchRemoteForRef:(nullable PBGitRef *)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)pullBranch:(nullable PBGitRef *)branchRef fromRemote:(nullable PBGitRef *)remoteRef rebase:(BOOL)rebase error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)pushBranch:(nullable PBGitRef *)branchRef toRemote:(nullable PBGitRef *)remoteRef error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)retryPushWithPlan:(PBRepositoryPushRetryPlan *)plan error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)deleteRemote:(nullable PBGitRef *)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

@interface PBRepositoryMutationService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (NSString *)performDiff:(PBGitCommit *)startCommit against:(nullable PBGitCommit *)diffCommit forFiles:(nullable NSArray<NSString *> *)filePaths;
- (BOOL)checkoutRefish:(id<PBGitRefish>)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)checkoutFiles:(nullable NSArray<NSString *> *)files fromRefish:(id<PBGitRefish>)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)deleteReference:(PBGitRef *)ref error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

@interface PBCommitPatchCopyResult : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) NSInteger copiedCount;
@property (nonatomic, readonly) NSInteger skippedCount;
@property (nonatomic, readonly, nullable, copy) NSString *warningMessage;
@property (nonatomic, readonly, copy) NSString *warningInfo;
@end

@interface GitXCommitCopier : NSValueTransformer
+ (BOOL)canCopyImmutableCommits:(NSArray<PBGitCommit *> *)commits;
+ (NSString *)toFullSHA:(NSArray<PBGitCommit *> *)commits;
+ (NSString *)toShortName:(NSArray<PBGitCommit *> *)commits;
+ (NSString *)toSHAAndHeadingString:(NSArray<PBGitCommit *> *)commits;
+ (PBCommitPatchCopyResult *)patchCopyResult:(NSArray<PBGitCommit *> *)commits;
+ (NSString *)toPatch:(NSArray<PBGitCommit *> *)commits;
+ (void)putStringToPasteboard:(nullable NSString *)text;
@end

@interface PBRepositoryStashService : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (BOOL)saveWithKeepIndex:(BOOL)keepIndex error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
@end

@interface PBIndexStatusEntry : NSObject
@property (nonatomic, copy, readonly) NSData *rawPath;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSInteger status;
@property (nonatomic, readonly, nullable) NSString *commitBlobMode;
@property (nonatomic, readonly, nullable) NSString *commitBlobSHA;
@end

@interface PBIndexStatusParser : NSObject
- (nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)parseTrackedData:(nullable NSData *)data
																	  error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)parseUntrackedData:(nullable NSData *)data
																		error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
@end

@interface PBIndexFileSnapshot : NSObject
@property (nonatomic, copy, readonly) NSData *rawPath;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic) NSInteger status;
@property (nonatomic) NSInteger stagedStatus;
@property (nonatomic) NSInteger worktreeStatus;
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

@interface PBIndexFileSnapshot (RawIdentity)
- (instancetype)initWithPath:(NSString *)path rawPath:(NSData *)rawPath status:(NSInteger)status stagedStatus:(NSInteger)stagedStatus worktreeStatus:(NSInteger)worktreeStatus commitBlobMode:(nullable NSString *)commitBlobMode commitBlobSHA:(nullable NSString *)commitBlobSHA hasStagedChanges:(BOOL)hasStagedChanges hasUnstagedChanges:(BOOL)hasUnstagedChanges;
@end

@interface PBIndexFilePresentation : NSObject
+ (NSString *)displayPathForRawPath:(NSData *)rawPath NS_SWIFT_NAME(displayPath(forRawPath:));
+ (nullable NSString *)safePathForRawPath:(NSData *)rawPath NS_SWIFT_NAME(safePath(forRawPath:));
+ (NSArray<NSData *> *)rawPathsFromData:(NSData *)data NS_SWIFT_NAME(rawPaths(from:));
+ (BOOL)pathMatchesRawPath:(nullable NSData *)rawPath fullPath:(nullable NSString *)fullPath NS_SWIFT_NAME(pathMatchesRawPath(_:fullPath:));
+ (NSString *)imageNameForStatus:(NSInteger)status;
+ (NSString *)workingStatusForFile:(PBChangedFile *)file NS_SWIFT_NAME(workingStatus(for:));
+ (NSArray<PBChangedFile *> *)discardableFilesFromFiles:(NSArray<PBChangedFile *> *)files NS_SWIFT_NAME(discardableFiles(from:));
@end

@interface PBIndexWorkingStateSummary : NSObject
@property (nonatomic, readonly) NSUInteger stagedCount;
@property (nonatomic, readonly) NSUInteger unstagedCount;
@property (nonatomic, readonly) NSUInteger untrackedCount;
- (instancetype)initWithFiles:(NSArray<PBChangedFile *> *)files;
@end

@interface PBIndexOperationErrorPresentation : NSObject
+ (NSString *)messageForOperation:(NSString *)operation error:(nullable NSError *)error NS_SWIFT_NAME(message(forOperation:error:));
@end

@interface PBIndexSnapshotReducer : NSObject
- (NSArray<PBIndexFileSnapshot *> *)reducePrevious:(NSArray<PBIndexFileSnapshot *> *)previous
											staged:(nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)staged
										  unstaged:(nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)unstaged
										 untracked:(nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)untracked;
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

typedef NS_ENUM(NSInteger, PBSyntheticUntrackedFileMode) {
	PBSyntheticUntrackedFileModeRegular,
	PBSyntheticUntrackedFileModeExecutable,
	PBSyntheticUntrackedFileModeSymbolicLink,
};

@interface PBSyntheticUntrackedDiffFormatter : NSObject
+ (NSString *)diffForPath:(NSString *)path contents:(NSString *)contents;
+ (NSString *)diffForPath:(NSString *)path contents:(NSString *)contents fileMode:(PBSyntheticUntrackedFileMode)fileMode;
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
- (PBNativeRenderResult *)renderSourceSections:(NSArray<PBNativeContentSection *> *)sections
							 shouldCancel:(BOOL (^)(void))shouldCancel;
- (PBNativeRenderResult *)renderBlameSections:(NSArray<PBNativeContentSection *> *)sections;
- (PBNativeRenderResult *)renderBlameSections:(NSArray<PBNativeContentSection *> *)sections
							shouldCancel:(BOOL (^)(void))shouldCancel;
- (PBNativeRenderResult *)renderHistorySections:(NSArray<PBNativeContentSection *> *)sections;
- (PBNativeRenderResult *)renderHistorySections:(NSArray<PBNativeContentSection *> *)sections
							  shouldCancel:(BOOL (^)(void))shouldCancel;
@end

@interface PBNativeDiffRenderer : NSObject
- (instancetype)initWithBaseAttributes:(NSDictionary<NSAttributedStringKey, id> *)baseAttributes
					titleAttributes:(NSDictionary<NSAttributedStringKey, id> *)titleAttributes
							parser:(PBDiffDocumentParser *)parser;
- (PBNativeRenderResult *)renderSections:(NSArray<PBNativeContentSection *> *)sections
						  collapsedFiles:(NSSet<NSString *> *)collapsedFiles
						  expandedImages:(NSSet<NSString *> *)expandedImages
					   imageDataProvider:(nullable NSData * (^)(NSString *path, NSInteger section, NSDictionary<NSString *, id> *imageSource))imageDataProvider;
- (PBNativeRenderResult *)renderSections:(NSArray<PBNativeContentSection *> *)sections
						  collapsedFiles:(NSSet<NSString *> *)collapsedFiles
						  expandedImages:(NSSet<NSString *> *)expandedImages
					   imageDataProvider:(nullable NSData * (^)(NSString *path, NSInteger section, NSDictionary<NSString *, id> *imageSource))imageDataProvider
						   shouldCancel:(BOOL (^)(void))shouldCancel;
@end

@interface PBNativeContentView (GitXTesting)
@property (nonatomic, readonly) NSOperationQueue *renderQueueForTesting;
@property (nonatomic, readonly) NSDictionary<NSString *, PBNativeRenderResult *> *cachedDiffResultsForTesting;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *cachedDiffSectionsForTesting;
@property (nonatomic, readonly) NSDictionary<NSString *, NSValue *> *cachedDiffScrollOriginsForTesting;
- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex;
@end

@protocol PBIndexCommandRunning <NSObject>
- (nullable NSString *)outputWithArguments:(NSArray<NSString *> *)arguments
									 input:(nullable NSString *)input
							   environment:(nullable NSDictionary<NSString *, id> *)environment
									 error:(NSError *_Nullable *_Nullable)error;
- (void)dataWithArguments:(NSArray<NSString *> *)arguments
			   completion:(void (^)(NSData *_Nullable data, NSError *_Nullable error))completion;
@end

@protocol PBIndexBinaryCommandRunning <PBIndexCommandRunning>
- (nullable NSString *)outputWithArguments:(NSArray<NSString *> *)arguments
								 inputData:(nullable NSData *)inputData
							   environment:(nullable NSDictionary<NSString *, id> *)environment
									 error:(NSError *_Nullable *_Nullable)error;
@end

__attribute__((objc_runtime_name("_TtC4GitX28IndexRepositoryCommandRunner")))
@interface IndexRepositoryCommandRunner : NSObject<PBIndexBinaryCommandRunning>
- (instancetype)initWithRepository:(PBGitRepository *)repository;
@end

@interface PBIndexRefreshResult : NSObject
@property (nonatomic, readonly) NSUInteger mutationGeneration;
- (instancetype)initWithStaged:(nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)staged unstaged:(nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)unstaged untracked:(nullable NSDictionary<NSData *, PBIndexStatusEntry *> *)untracked mutationGeneration:(NSUInteger)mutationGeneration;
@property (nonatomic, readonly, nullable) NSDictionary<NSData *, PBIndexStatusEntry *> *staged;
@property (nonatomic, readonly, nullable) NSDictionary<NSData *, PBIndexStatusEntry *> *unstaged;
@property (nonatomic, readonly, nullable) NSDictionary<NSData *, PBIndexStatusEntry *> *untracked;
@end

@interface PBIndexFileReconciliation : NSObject
@property (nonatomic, copy, readonly) NSArray<PBChangedFile *> *files;
@property (nonatomic, readonly) BOOL membershipChanged;
- (instancetype)initWithFiles:(NSArray<PBChangedFile *> *)files result:(PBIndexRefreshResult *)result reducer:(PBIndexSnapshotReducer *)reducer;
@end

@interface PBGitIndex (RecoveryTesting)
- (nullable NSArray<NSString *> *)literalArgumentsForRawPath:(NSData *)rawPath commandArguments:(NSArray<NSString *> *)commandArguments error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(literalArguments(forRawPath:commandArguments:error:)) __attribute__((swift_error(none)));
- (void)applyRefreshResult:(PBIndexRefreshResult *)result NS_SWIFT_NAME(applyRefreshResult(_:));
- (void)postIndexRefreshFinished NS_SWIFT_NAME(postIndexRefreshFinished());
@end

@interface PBIndexPreviewImageSource : NSObject
+ (NSDictionary<NSString *, id> *)sourceFromWorkingSource:(NSDictionary<NSString *, id> *)source staged:(BOOL)staged NS_SWIFT_NAME(source(workingSource:staged:));
@end

@class PBIndexFileViewSnapshot;
@interface PBIndexFileViewSnapshotLookup : NSObject
- (instancetype)initWithSnapshots:(NSArray<PBIndexFileViewSnapshot *> *)snapshots;
- (nullable PBIndexFileViewSnapshot *)snapshotForRawPath:(NSData *)rawPath NS_SWIFT_NAME(snapshot(rawPath:));
@end

@interface PBIndexFileViewSnapshot : NSObject
@property (nonatomic, copy, readonly) NSData *rawPath;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, readonly) NSInteger stagedStatus;
@property (nonatomic, readonly) NSInteger worktreeStatus;
@property (nonatomic, readonly) BOOL hasStagedChanges;
@property (nonatomic, readonly) BOOL hasUnstagedChanges;
+ (NSArray<PBIndexFileViewSnapshot *> *)snapshotsForFiles:(NSArray<PBChangedFile *> *)files NS_SWIFT_NAME(snapshots(forFiles:));
+ (NSArray<PBIndexFileViewSnapshot *> *)snapshotsForFiles:(NSArray<PBChangedFile *> *)files rawPaths:(NSArray<NSData *> *)rawPaths NS_SWIFT_NAME(snapshots(forFiles:rawPaths:));
- (PBChangedFile *)materializedFile;
@end

@interface PBIndexRefreshCoordinator : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository
							parser:(PBIndexStatusParser *)parser
					 statusHandler:(void (^)(BOOL success, NSString *message))statusHandler
					 resultHandler:(void (^)(PBIndexRefreshResult *result))resultHandler
					   idleHandler:(void (^)(void))idleHandler;
- (instancetype)initWithRunner:(id<PBIndexCommandRunning>)runner
						parser:(PBIndexStatusParser *)parser
				 statusHandler:(void (^)(BOOL success, NSString *message))statusHandler
				 resultHandler:(void (^)(PBIndexRefreshResult *result))resultHandler
				   idleHandler:(void (^)(void))idleHandler;
- (void)refreshBareRepository:(BOOL)bareRepository parentTree:(NSString *)parentTree;
- (void)refreshBareRepository:(BOOL)bareRepository parentTree:(NSString *)parentTree mutationGeneration:(NSUInteger)mutationGeneration;
- (void)refreshStatCacheForBareRepository:(BOOL)bareRepository completion:(void (^)(void))completion;
@end

@protocol PBIndexHookRunning <NSObject>
- (BOOL)executeHook:(NSString *)name
		  arguments:(NSArray<NSString *> *)arguments
			  error:(NSError *_Nullable *_Nullable)error
	  outputHandler:(void (^)(NSData *data))outputHandler;
@end

typedef NS_ENUM(NSInteger, PBIndexCommitResultKind) {
	PBIndexCommitResultKindSuccess,
	PBIndexCommitResultKindFailure,
	PBIndexCommitResultKindHookFailure,
};

@interface PBIndexCommitRequest : NSObject
@property (readonly) NSString *message;
@property (readonly) BOOL verify;
@property (readonly) BOOL gpgSign;
@property (readonly) BOOL amend;
@property (readonly, nullable) NSDictionary<NSString *, id> *environment;
@property (readonly) NSArray<NSString *> *parentSHAs;
@property (readonly) BOOL hasHead;
- (PBIndexCommitRequest *)requestWithoutVerification NS_SWIFT_NAME(withoutVerification());
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

typedef NS_ENUM(NSInteger, PBIndexCommitPhase) {
    PBIndexCommitPhaseCreatingTree,
    PBIndexCommitPhaseCreatingCommit,
    PBIndexCommitPhaseRunningPreCommitHook,
    PBIndexCommitPhaseRunningCommitMessageHook,
    PBIndexCommitPhaseUpdatingHead,
    PBIndexCommitPhaseRunningPostCommitHook,
};

@interface PBIndexCommitEvent : NSObject
@end

@interface PBIndexCommitPhaseEvent : PBIndexCommitEvent
@property (nonatomic, readonly) PBIndexCommitPhase phase;
@property (nonatomic, copy, readonly) NSString *displayName;
@end

@interface PBIndexCommitOutputEvent : PBIndexCommitEvent
@property (nonatomic, copy, readonly) NSString *output;
@end

@interface PBIndexCommitCompletionEvent : PBIndexCommitEvent
@property (nonatomic, strong, readonly) PBIndexCommitResult *result;
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
- (PBIndexCommitResult *)commitWithRequest:(PBIndexCommitRequest *)request
                              eventHandler:(void (^)(PBIndexCommitEvent *event))eventHandler;
@end

@interface PBIndexCommitCoordinator : NSObject
- (instancetype)initWithService:(PBIndexCommitService *)service
                     repository:(nullable PBGitRepository *)repository;
- (void)commitWithRequest:(PBIndexCommitRequest *)request
             eventHandler:(void (^)(PBIndexCommitEvent *event))eventHandler;
@end

@interface PBIncrementalUTF8Decoder : NSObject
- (NSString *)appendData:(NSData *)data NS_SWIFT_NAME(append(_:));
- (NSString *)finish;
@end

@interface PBCommitProgressSheetController : NSWindowController
- (instancetype)initWithParentWindow:(nullable NSWindow *)parentWindow;
- (void)beginWithPhase:(NSString *)phase;
- (void)updatePhase:(NSString *)phase;
- (void)appendOutput:(NSString *)output;
- (void)finish;
@end

@interface PBIndexMutationService : NSObject
- (BOOL)stageRawPaths:(NSArray<NSData *> *)paths unstageRawPaths:(NSArray<NSData *> *)unstagePaths parentTree:(NSString *)parentTree error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(mutate(stageRawPaths:unstageRawPaths:parentTree:error:)) __attribute__((swift_error(none)));
- (nullable NSArray<NSString *> *)literalArgumentsForRawPath:(NSData *)rawPath commandArguments:(NSArray<NSString *> *)commandArguments error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(literalArguments(forRawPath:commandArguments:error:)) __attribute__((swift_error(none)));
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (nullable NSArray<NSString *> *)diffToolArgumentsForRawPath:(NSData *)rawPath staged:(BOOL)staged error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(diffToolArguments(forRawPath:staged:error:)) __attribute__((swift_error(none)));
- (BOOL)stageRawPaths:(NSArray<NSData *> *)paths error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (BOOL)unstageRawPaths:(NSArray<NSData *> *)paths parentTree:(NSString *)parentTree error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (BOOL)discardRawPaths:(NSArray<NSData *> *)paths error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
- (nullable NSString *)diffForRawPath:(NSData *)rawPath displayPath:(NSString *)displayPath status:(NSInteger)status hasStagedChanges:(BOOL)hasStagedChanges staged:(BOOL)staged parentTree:(NSString *)parentTree contextLines:(NSUInteger)contextLines ignoreWhitespace:(BOOL)ignoreWhitespace error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
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
- (nullable NSString *)diffForPath:(NSString *)path
							status:(NSInteger)status
				  hasStagedChanges:(BOOL)hasStagedChanges
							staged:(BOOL)staged
						parentTree:(NSString *)parentTree
					  contextLines:(NSUInteger)contextLines
				  ignoreWhitespace:(BOOL)ignoreWhitespace
							 error:(NSError *_Nullable *_Nullable)error __attribute__((swift_error(none)));
@end

@interface PBIndexGitExecutableIdentity : NSObject
+ (NSString *)identityForPath:(NSString *)path NS_SWIFT_NAME(identity(forPath:));
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
@property (nonatomic, strong, nullable) NSNumber *pendingRememberedPushChoice;
@property (nonatomic, readonly) BOOL submissionActive;
- (void)beginSubmissionWithPushChoice:(BOOL)pushChoice canRemember:(BOOL)canRemember
	NS_SWIFT_NAME(beginSubmission(pushChoice:canRemember:));
- (void)armWithBranchRef:(PBGitRef *)branchRef remoteName:(NSString *)remoteName
	NS_SWIFT_NAME(arm(branchRef:remoteName:));
- (void)clear;
- (nullable NSNumber *)cancelSubmission;
- (nullable NSNumber *)consumeRememberedPushChoice;
- (void)updateRememberedPushChoice:(BOOL)choice;
- (nullable PBCommitPushPlan *)consumePendingPush;
@end

@interface PBRepositoryToolbarController : NSObject
- (instancetype)initWithWindowController:(PBGitWindowController *)windowController;
- (void)install;
- (void)updateWithStatus:(NSString *)status busy:(BOOL)busy baseWindowTitle:(NSString *)baseWindowTitle;
- (void)updateWithForgePersistentFailureText:(nullable NSString *)persistentFailureText
	statusBarVisible:(BOOL)statusBarVisible
	NS_SWIFT_NAME(updateForgeDiagnostic(persistentFailureText:statusBarVisible:));
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
- (nullable NSToolbarItem *)toolbar:(NSToolbar *)toolbar
			  itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
		  willBeInsertedIntoToolbar:(BOOL)flag;
- (void)menuNeedsUpdate:(NSMenu *)menu;
@end

@interface PBRepositoryForgeLinkMenuPresenter : NSObject
+ (NSArray<NSMenuItem *> *)menuItemsForProviderName:(nullable NSString *)providerName
								 forgeAvailable:(BOOL)forgeAvailable
							 currentBranchName:(nullable NSString *)currentBranchName
				 checkedOutCommitIdentifier:(nullable NSString *)checkedOutCommitIdentifier
					 selectedCommitIdentifiers:(NSArray<NSString *> *)selectedCommitIdentifiers;
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
									   resolvedFiles:(NSArray<PBCommitMenuFile *> *)resolvedFiles
										allowsTrash:(BOOL)allowsTrash
								   isContextualMenu:(BOOL)isContextualMenu
						 singleSelectionIsSubmodule:(BOOL)singleSelectionIsSubmodule
											isAmend:(BOOL)isAmend
								  prepareHookExists:(BOOL)prepareHookExists
									fallbackEnabled:(BOOL)fallbackEnabled
	NS_SWIFT_NAME(presentation(action:resolvedFiles:allowsTrash:isContextualMenu:singleSelectionIsSubmodule:isAmend:prepareHookExists:fallbackEnabled:));
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
@property (nonatomic, copy) NSString *sha;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL leaf;
@property (nonatomic, weak) PBGitRepository *repository;
@property (nonatomic, weak) PBGitTree *parent;
@property (nonatomic, readonly) NSArray<PBGitTree *> *children;
@property (nonatomic, readonly) NSString *contents;
@property (nonatomic, readonly) NSString *fullPath;
@property (nonatomic, readonly) NSString *displayPath;
- (long long)fileSize;
- (NSString *)textContents;
- (NSString *)blame;
- (NSString *)log:(NSString *)format;
- (NSString *)tmpFileNameForContents;
- (void)saveToFolder:(NSString *)directory;
@end

@interface PBWorkingTree : PBGitTree
@property (nonatomic, copy, readonly, nullable) NSData *rawPath;
+ (instancetype)rootForRepository:(PBGitRepository *)repository NS_SWIFT_NAME(root(for:));
@end

@interface PBWorkingTreePaths : NSObject
- (instancetype)initWithFiles:(NSArray<PBChangedFile *> *)files;
@property (nonatomic, readonly) NSArray<NSData *> *rawPaths;
- (void)appendData:(NSData *)data NS_SWIFT_NAME(append(data:));
- (nullable PBChangedFile *)fileForRawPath:(NSData *)rawPath NS_SWIFT_NAME(file(for:));
+ (nullable NSString *)validatedHierarchyPath:(NSString *)path;
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
- (void)historyTraversalSettingsDidChange:(NSNotification *)notification;
- (void)historyTreeSettingsDidChange:(NSNotification *)notification;
- (void)outlineView:(NSOutlineView *)outlineView
    willDisplayCell:(NSTextFieldCell *)cell
     forTableColumn:(nullable NSTableColumn *)tableColumn
               item:(id)item;
- (nullable NSString *)outlineView:(NSOutlineView *)outlineView
                    toolTipForCell:(NSCell *)cell
                               rect:(nullable NSRectPointer)rect
                        tableColumn:(nullable NSTableColumn *)tableColumn
                               item:(id)item
                      mouseLocation:(NSPoint)mouseLocation;
- (void)_repositoryUpdatedNotification:(NSNotification *)notification;
- (void)performFindPanelAction:(id)sender;
- (BOOL)isCommitSelected;
- (void)checkoutFiles:(id)sender;
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(nullable id)panel;
- (nullable id<QLPreviewItem>)previewPanel:(nullable id)panel previewItemAtIndex:(NSInteger)index;
- (BOOL)previewPanel:(nullable id)panel handleEvent:(NSEvent *)event;
- (NSRect)previewPanel:(nullable id)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item;
@end

@interface PBRepositoryUISettings : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
@property (nonatomic) BOOL hideContainedBranches;
@property (nonatomic) BOOL pushAfterCommit;
@property (nonatomic) BOOL historyRepositoryFactsInspectorVisible;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *sidebarVisibility;
- (BOOL)isSidebarGroupVisible:(NSString *)group;
@end

typedef NS_ENUM(NSInteger, PBRepositoryForgeBindingResolutionKind) {
	PBRepositoryForgeBindingResolutionKindExisting,
	PBRepositoryForgeBindingResolutionKindAutomatic,
	PBRepositoryForgeBindingResolutionKindRequiresChoice,
	PBRepositoryForgeBindingResolutionKindUnavailable,
};

typedef NS_ENUM(NSInteger, PBRepositoryForgeRevisionKind) {
	PBRepositoryForgeRevisionKindBranch,
	PBRepositoryForgeRevisionKindTag,
	PBRepositoryForgeRevisionKindCommit,
};

typedef NS_ENUM(NSInteger, PBRepositoryForgeScriptingErrorCode) {
	PBRepositoryForgeScriptingErrorCodeNoForgeRepository = 18001,
	PBRepositoryForgeScriptingErrorCodeAmbiguousForgeRepository = 18002,
	PBRepositoryForgeScriptingErrorCodeInvalidDestination = 18003,
	PBRepositoryForgeScriptingErrorCodeAmbiguousDestination = 18004,
	PBRepositoryForgeScriptingErrorCodeNoAvailableDestination = 18005,
};

@interface PBRepositoryForgeBindingCandidate : NSObject
@property (nonatomic, readonly, copy) NSString *localRemoteName;
@property (nonatomic, readonly, copy) NSString *providerName;
@property (nonatomic, readonly, copy) NSString *repositoryLabel;
@property (nonatomic, readonly, nullable) NSURL *repositoryURL;
@end

@interface PBRepositoryForgeBindingResolution : NSObject
@property (nonatomic, readonly) PBRepositoryForgeBindingResolutionKind kind;
@property (nonatomic, readonly, copy) NSArray<PBRepositoryForgeBindingCandidate *> *candidates;
@property (nonatomic, readonly, copy, nullable) NSString *localRemoteName;
@property (nonatomic, readonly, nullable) NSURL *repositoryURL;
@property (nonatomic, readonly, copy, nullable) NSString *providerName;
@end

@interface PBRepositoryForgeCoordinator : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (PBRepositoryForgeBindingResolution *)resolveBinding;
- (nullable PBRepositoryForgeBindingResolution *)selectCandidate:(PBRepositoryForgeBindingCandidate *)candidate
														 error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)repositoryURLWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)branchURLForName:(NSString *)name
									 error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)commitURLForIdentifier:(NSString *)identifier
										 error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)fileURLForRevision:(NSString *)revision
							  revisionKind:(PBRepositoryForgeRevisionKind)revisionKind
										 path:(NSString *)path
								 startLine:(nullable NSNumber *)startLine
								   endLine:(nullable NSNumber *)endLine
									 error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)compareURLFromRevision:(NSString *)base
									 baseKind:(PBRepositoryForgeRevisionKind)baseKind
								toRevision:(NSString *)head
									 headKind:(PBRepositoryForgeRevisionKind)headKind
										error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)pullRequestURLForNumber:(NSInteger)number
											error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)issueURLForNumber:(NSInteger)number
									  error:(NSError * _Nullable * _Nullable)error;
@end

@interface PBForgeDestinationScriptCommand : NSScriptCommand
@end

NS_ASSUME_NONNULL_END

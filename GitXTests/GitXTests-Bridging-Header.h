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

NS_ASSUME_NONNULL_BEGIN

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
+ (PBApplicationComposition *)sharedComposition;
+ (void)setSharedComposition:(PBApplicationComposition *)composition;
@end

@interface PBApplicationSettings : NSObject
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
@end

@interface PBStagingSectionHeaderView : NSView
@property (nonatomic, readonly) NSButton *masterCheckbox;
- (void)configureWithTitle:(NSString *)title fileCount:(NSInteger)fileCount masterState:(NSInteger)masterState
	NS_SWIFT_NAME(configure(title:fileCount:masterState:));
@end

@interface PBCommitTableInteractionCoordinator : NSObject
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

@interface PBHistoryStateCoordinator : NSObject
- (NSArray<PBGitCommit *> *)normalizedSelection:(NSArray<PBGitCommit *> *)selection;
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

@protocol PBGitCommandRunning <NSObject>
@property (nonatomic, copy, readonly, nullable) NSString *lastOutput;
- (nullable NSString *)outputWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
- (BOOL)launchWithArguments:(NSArray<NSString *> *)arguments error:(NSError * _Nullable * _Nullable)error;
@end

@interface PBRepositoryReferenceStore : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository runner:(id<PBGitCommandRunning>)runner;
- (nullable PBGitRef *)refForName:(nullable NSString *)name;
@end

@interface PBRepositoryRemoteService : NSObject
@property (nonatomic, copy, readonly, nullable) NSString *lastPushOutput;
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
              error:(NSError * _Nullable * _Nullable)error
       outputHandler:(void (^)(NSData *data))outputHandler;
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
- (void)beginSubmissionWithPushChoice:(BOOL)pushChoice canRemember:(BOOL)canRemember
	NS_SWIFT_NAME(beginSubmission(pushChoice:canRemember:));
- (void)armWithBranchRef:(PBGitRef *)branchRef remoteName:(NSString *)remoteName
	NS_SWIFT_NAME(arm(branchRef:remoteName:));
- (void)clear;
- (nullable NSNumber *)cancelSubmission;
- (nullable NSNumber *)consumeRememberedPushChoice;
- (nullable PBCommitPushPlan *)consumePendingPush;
@end

@interface PBRepositoryToolbarController : NSObject
- (instancetype)initWithWindowController:(PBGitWindowController *)windowController;
- (void)install;
- (void)updateWithStatus:(NSString *)status busy:(BOOL)busy baseWindowTitle:(NSString *)baseWindowTitle;
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

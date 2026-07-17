#import <Cocoa/Cocoa.h>
#import <ObjectiveGit/ObjectiveGit.h>
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "PBMacros.h"
#import "PBAutoFetchManager.h"
#import "PBAddRemoteSheet.h"
#import "PBChangedFile.h"
#import "PBCommitHookFailedSheet.h"
#import "PBCommitList.h"
#import "PBCommitMessageView.h"
#import "PBCreateBranchSheet.h"
#import "PBCreateTagSheet.h"
#import "PBDiffWindowController.h"
#import "PBGitCommit.h"
#import "PBGitCommitController.h"
#import "PBGitDefaults.h"
#import "PBGitHistoryController.h"
#import "PBGitHistoryList.h"
#import "PBGitIndex.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitRepositoryWatcher.h"
#import "PBGitRevSpecifier.h"
#import "PBGitSidebarController.h"
#import "PBGitStash.h"
#import "PBGitTree.h"
#import "PBGitWindowController.h"
#import "PBGitXMessageSheet.h"
#import "PBError.h"
#import "PBFileChangesTableView.h"
#import "GLFileView.h"
#import "PBNativeContentView.h"
#import "PBRemoteProgressSheet.h"
#import "PBSourceViewItem.h"
#import "PBTask.h"
#import "PBTerminalUtil.h"
#import "PBPrefsWindowController.h"
#import "PBViewController.h"

@interface PBRepositoryToolbarController : NSObject
- (instancetype)initWithWindowController:(PBGitWindowController *)windowController;
- (void)install;
- (void)setHistoryMode:(BOOL)historyMode;
- (void)updateWithStatus:(NSString *)status busy:(BOOL)busy baseWindowTitle:(NSString *)baseWindowTitle;
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
@end

@interface PBCommitLayoutCoordinator : NSObject
+ (void)configureOuterSplitView:(NSSplitView *)outerSplitView
			  commitMessageView:(NSTextView *)commitMessageView
				  unstagedTable:(NSTableView *)unstagedTable
					stagedTable:(NSTableView *)stagedTable;
@end

@interface PBRecentRepositoryStore : NSObject
+ (instancetype)shared;
- (void)record:(NSURL *)url;
@end

@interface PBGitSidebarController (WindowControllerTests)
- (void)reloadSidebarAfterReferencesChange;
@end

@interface PBCommitMessageTransformer : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (nullable NSString *)transformMessage:(NSString *)message error:(NSError **)error;
@end

@interface PBCommitMessageEditCoordinator : NSObject
+ (nullable NSString *)transformMessage:(NSString *)message
							 inTextView:(NSTextView *)textView
							 repository:(PBGitRepository *)repository
								  error:(NSError **)error;
@end

@interface PBRepositoryRemoteURLCoordinator : NSObject
+ (instancetype)shared;
- (nullable NSURL *)firstHTTPURLInOutput:(NSString *)output;
- (nullable NSURL *)webURLForRemoteURL:(NSString *)remoteURL branch:(NSString *)branch sha:(NSString *)sha;
@end

@interface PBHistoryTreePresentation : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (PBGitTree *)treeForCommit:(PBGitCommit *)commit;
- (NSString *)displayTitleForTree:(PBGitTree *)tree;
- (NSString *)toolTipForTree:(PBGitTree *)tree;
@end

@interface PBHistoryStateCoordinator : NSObject
- (void)saveFileBrowserSelectionFromSelectedObjects:(NSArray<NSObject *> *)selectedObjects hasContent:(BOOL)hasContent;
- (nullable NSIndexPath *)treeSelectionIndexPathForChildren:(NSArray<NSObject *> *)children treeMode:(BOOL)treeMode;
@end

@interface GLFileView (WindowControllerTests)
- (NSArray<NSDictionary *> *)historyEntriesForTree:(PBGitTree *)file;
@end

@interface PBApplicationSettings : NSObject
+ (BOOL)changedFilesOnly;
+ (void)setChangedFilesOnly:(BOOL)value;
+ (NSInteger)changedFilesSort;
+ (void)setChangedFilesSort:(NSInteger)value;
+ (NSInteger)diffLayout;
@end

@interface PBNativeDiffSectionSettings : NSObject
+ (NSArray<NSDictionary *> *)applyToSections:(NSArray<NSDictionary *> *)sections repository:(PBGitRepository *)repository;
@end

@interface PBWindowHistoryTreeLogStub : PBGitTree
@end

@interface PBWindowRepositoryWithoutGitURLs : PBGitRepository
@end

@interface PBWelcomeWindowController : NSWindowController
+ (instancetype)shared;
- (void)searchChanged:(nullable id)sender;
- (void)closeWelcome;
@end

@interface PBRepositoryUISettings : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
@property (nonatomic) BOOL pushAfterCommit;
@end

@implementation PBWindowHistoryTreeLogStub

- (NSString *)log:(NSString *)format
{
	NSDictionary<NSString *, NSString *> *replacements = @{
		@"%h" : @"abc1234",
		@"%s" : @"Toolbar history",
		@"%aN" : @"Ada",
		@"%ar" : @"now",
		@"%H" : @"abc123456789",
	};
	NSString *output = format;
	for (NSString *placeholder in replacements) {
		output = [output stringByReplacingOccurrencesOfString:placeholder withString:replacements[placeholder]];
	}
	return [output stringByAppendingString:@"malformed trailing record"];
}

@end

@implementation PBWindowRepositoryWithoutGitURLs

- (nullable NSString *)outputOfTaskWithArguments:(nullable NSArray *)arguments error:(NSError **)error
{
	return @"";
}

- (nullable NSURL *)gitURL
{
	return nil;
}

- (nullable NSURL *)workingDirectoryURL
{
	return nil;
}

@end

@interface PBGitWindowController (WindowControllerTests)
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)refreshPreferenceDidChange:(nullable NSNotification *)notification;
- (void)refreshIfRepositoryChangedSinceLastActivation;
- (void)removeAllContentSubViews;
- (void)updateStatus;
- (nullable NSArray<NSURL *> *)selectedURLsFromSender:(id)sender;
- (nullable id<PBGitRefish>)refishForSender:(id)sender refishTypes:(nullable NSArray<NSString *> *)types;
- (nullable PBGitRef *)selectedRef;
- (BOOL)isShowingCommitView;
- (IBAction)toolbarFetch:(id)sender;
- (IBAction)toolbarPull:(id)sender;
- (IBAction)toolbarPush:(id)sender;
- (IBAction)viewRemote:(id)sender;
@end

@interface PBGitCommitController (WindowControllerTests)
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)repositoryUpdatedNotification:(NSNotification *)notification;
- (nullable NSString *)selectedPushRemoteName;
- (void)reloadPushRemotes;
- (void)commitWithVerification:(BOOL)doVerify;
- (void)discardChangesForFiles:(NSArray<PBChangedFile *> *)files force:(BOOL)force;
- (NSArray<PBChangedFile *> *)selectedFilesForSender:(id)sender;
- (void)refreshFinished:(NSNotification *)notification;
- (void)commitStatusUpdated:(NSNotification *)notification;
- (void)commitFinished:(NSNotification *)notification;
- (void)commitFailed:(NSNotification *)notification;
- (void)commitHookFailed:(NSNotification *)notification;
- (void)amendCommit:(NSNotification *)notification;
- (void)indexChanged:(NSNotification *)notification;
- (void)indexOperationFailed:(NSNotification *)notification;
- (void)focusTable:(NSTableView *)table;
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector;
- (void)didDoubleClickOnTable:(NSTableView *)tableView;
- (void)menuNeedsUpdate:(NSMenu *)menu;
- (IBAction)toggleAmendCommit:(id)sender;
- (IBAction)openFiles:(id)sender;
- (IBAction)revealInFinder:(id)sender;
- (IBAction)moveToTrash:(id)sender;
- (IBAction)ignoreFiles:(id)sender;
- (IBAction)stageFiles:(id)sender;
- (IBAction)unstageFiles:(id)sender;
- (IBAction)discardFiles:(id)sender;
- (IBAction)discardFilesForcibly:(id)sender;
- (void)fileChangesTableViewDidRequestStagingToggle:(PBFileChangesTableView *)tableView;
- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex;
- (BOOL)tableView:(NSTableView *)tableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pasteboard;
- (NSDragOperation)tableView:(NSTableView *)tableView
				validateDrop:(id<NSDraggingInfo>)info
				 proposedRow:(NSInteger)row
	   proposedDropOperation:(NSTableViewDropOperation)operation;
- (BOOL)tableView:(NSTableView *)tableView
	   acceptDrop:(id<NSDraggingInfo>)info
			  row:(NSInteger)row
	dropOperation:(NSTableViewDropOperation)operation;
@end

static NSModalResponse PBWindowAlertResponse;
static NSControlStateValue PBWindowAlertSuppressionState;
static NSModalResponse PBWindowAddRemoteResponse;
static NSModalResponse PBWindowCreateBranchResponse;
static NSModalResponse PBWindowCreateTagResponse;
static NSModalResponse PBWindowHookResponse;
static NSUInteger PBWindowWorkspaceOpenCount;
static NSUInteger PBWindowWorkspaceRevealCount;
static NSUInteger PBWindowDocumentOpenCount;
static NSUInteger PBWindowMessageCount;
static NSUInteger PBWindowErrorMessageCount;
static NSUInteger PBWindowHookCount;
static NSUInteger PBWindowDiffCount;
static NSUInteger PBWindowStashDiffCount;
static NSUInteger PBWindowTerminalCount;
static NSUInteger PBWindowManualFetchCount;
static NSString *PBWindowLastProgressTitle;
static NSString *PBWindowLastProgressDescription;
static NSString *PBWindowLastMessage;
static NSString *PBWindowLastInfo;
static NSString *PBWindowLastTerminalCommand;
static NSURL *PBWindowLastTerminalDirectory;
static BOOL PBWindowUseSnapshotTaskFake;
static NSData *PBWindowSnapshotData;
static NSError *PBWindowSnapshotError;
static BOOL PBWindowTrashSucceeds;
static NSUInteger PBWindowTrashCount;
static BOOL PBWindowConfigurationMissingIdentity;

static void PBSwapInstanceMethods(Class cls, SEL original, SEL replacement)
{
	method_exchangeImplementations(class_getInstanceMethod(cls, original), class_getInstanceMethod(cls, replacement));
}

static void PBSwapClassMethods(Class cls, SEL original, SEL replacement)
{
	method_exchangeImplementations(class_getClassMethod(cls, original), class_getClassMethod(cls, replacement));
}

static void PBWindowSendObject(id target, SEL selector, id object)
{
	((void (*)(id, SEL, id))objc_msgSend)(target, selector, object);
}

static void PBWindowPerformPull(PBGitWindowController *controller, PBGitRef *branch, PBGitRef *remote, BOOL rebase)
{
	((void (*)(id, SEL, PBGitRef *, PBGitRef *, BOOL))objc_msgSend)(controller, @selector(performPullForBranch:remote:rebase:), branch, remote, rebase);
}

@interface PBWindowSnapshotTask : PBTask
@end

@implementation PBWindowSnapshotTask

- (void)performTaskWithCompletionHandler:(void (^)(NSData *, NSError *))completionHandler
{
	completionHandler(PBWindowSnapshotError ? nil : (PBWindowSnapshotData ?: NSData.data), PBWindowSnapshotError);
}

@end

@interface PBTask (WindowControllerTests)
+ (instancetype)pb_window_taskWithLaunchPath:(NSString *)launchPath arguments:(NSArray *)arguments inDirectory:(NSString *)directory;
@end

@implementation PBTask (WindowControllerTests)

+ (instancetype)pb_window_taskWithLaunchPath:(NSString *)launchPath arguments:(NSArray *)arguments inDirectory:(NSString *)directory
{
	PBTask *task = [self pb_window_taskWithLaunchPath:launchPath arguments:arguments inDirectory:directory];
	NSString *command = arguments.firstObject;
	BOOL isSnapshotCommand = [command isEqualToString:@"for-each-ref"] || [command isEqualToString:@"remote"] || [command isEqualToString:@"status"];
	if (PBWindowUseSnapshotTaskFake && isSnapshotCommand) {
		object_setClass(task, PBWindowSnapshotTask.class);
	}
	return task;
}

@end

@interface GTConfiguration (WindowControllerTests)
- (nullable NSString *)pb_window_stringForKey:(NSString *)key;
@end

@implementation GTConfiguration (WindowControllerTests)

- (NSString *)pb_window_stringForKey:(NSString *)key
{
	if (PBWindowConfigurationMissingIdentity && [key isEqualToString:@"user.email"]) return nil;
	return [self pb_window_stringForKey:key];
}

@end

@interface NSFileManager (WindowControllerTests)
- (BOOL)pb_window_trashItemAtURL:(NSURL *)url resultingItemURL:(NSURL *_Nullable *_Nullable)outResultingURL error:(NSError *_Nullable *_Nullable)error;
@end

@implementation NSFileManager (WindowControllerTests)

- (BOOL)pb_window_trashItemAtURL:(NSURL *)url resultingItemURL:(NSURL *_Nullable *_Nullable)outResultingURL error:(NSError *_Nullable *_Nullable)error
{
	PBWindowTrashCount++;
	if (PBWindowTrashSucceeds && outResultingURL) *outResultingURL = url;
	if (!PBWindowTrashSucceeds && error)
		*error = [NSError errorWithDomain:@"WindowControllerTests" code:99 userInfo:nil];
	return PBWindowTrashSucceeds;
}

@end

@interface PBWindowProgressSheet : PBRemoteProgressSheet
@end

static BOOL PBWindowRunProgressInBackground;
static XCTestExpectation *PBWindowProgressExpectation;

@implementation PBWindowProgressSheet

- (void)beginProgressSheetForBlock:(PBProgressSheetExecutionHandler)executionBlock completionHandler:(void (^)(NSError *))completionHandler
{
	if (PBWindowRunProgressInBackground) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSError *error = executionBlock();
			dispatch_async(dispatch_get_main_queue(), ^{
				completionHandler(error);
				[PBWindowProgressExpectation fulfill];
			});
		});
		return;
	}
	completionHandler(executionBlock());
}

@end

@interface PBRemoteProgressSheet (WindowControllerTests)
+ (instancetype)pb_window_progressSheetWithTitle:(NSString *)title description:(NSString *)description windowController:(PBGitWindowController *)windowController;
@end

@implementation PBRemoteProgressSheet (WindowControllerTests)

+ (instancetype)pb_window_progressSheetWithTitle:(NSString *)title description:(NSString *)description windowController:(PBGitWindowController *)windowController
{
	PBWindowLastProgressTitle = title;
	PBWindowLastProgressDescription = description;
	return [[PBWindowProgressSheet alloc] initWithWindow:nil];
}

@end

@interface PBWindowAddRemoteSheet : PBAddRemoteSheet
@property (nonatomic, strong) NSTextField *testRemoteName;
@property (nonatomic, strong) NSTextField *testRemoteURL;
@end

@implementation PBWindowAddRemoteSheet
- (NSTextField *)remoteName
{
	return self.testRemoteName;
}
- (NSTextField *)remoteURL
{
	return self.testRemoteURL;
}
@end

static PBWindowAddRemoteSheet *PBWindowAddRemoteTestSheet;

@interface PBAddRemoteSheet (WindowControllerTests)
+ (void)pb_window_beginSheetWithWindowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler;
@end

@implementation PBAddRemoteSheet (WindowControllerTests)

+ (void)pb_window_beginSheetWithWindowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler
{
	handler(PBWindowAddRemoteTestSheet, PBWindowAddRemoteResponse);
}

@end

@interface PBWindowCreateBranchSheet : PBCreateBranchSheet
@property (nonatomic, strong) NSTextField *testBranchNameField;
@end

@implementation PBWindowCreateBranchSheet
- (NSTextField *)branchNameField
{
	return self.testBranchNameField;
}
@end

static PBWindowCreateBranchSheet *PBWindowCreateBranchTestSheet;

@interface PBCreateBranchSheet (WindowControllerTests)
+ (void)pb_window_beginSheetWithRefish:(id<PBGitRefish>)ref windowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler;
@end

@implementation PBCreateBranchSheet (WindowControllerTests)

+ (void)pb_window_beginSheetWithRefish:(id<PBGitRefish>)ref windowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler
{
	PBWindowCreateBranchTestSheet.startRefish = ref;
	handler(PBWindowCreateBranchTestSheet, PBWindowCreateBranchResponse);
}

@end

@interface PBWindowCreateTagSheet : PBCreateTagSheet
@property (nonatomic, strong) NSTextField *testTagNameField;
@property (nonatomic, strong) NSTextView *testTagMessageText;
@end

@implementation PBWindowCreateTagSheet
- (NSTextField *)tagNameField
{
	return self.testTagNameField;
}
- (NSTextView *)tagMessageText
{
	return self.testTagMessageText;
}
@end

static PBWindowCreateTagSheet *PBWindowCreateTagTestSheet;

@interface PBCreateTagSheet (WindowControllerTests)
+ (void)pb_window_beginSheetWithRefish:(id<PBGitRefish>)refish windowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler;
@end

@implementation PBCreateTagSheet (WindowControllerTests)

+ (void)pb_window_beginSheetWithRefish:(id<PBGitRefish>)refish windowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler
{
	PBWindowCreateTagTestSheet.targetRefish = refish;
	handler(PBWindowCreateTagTestSheet, PBWindowCreateTagResponse);
}

@end

@interface NSAlert (WindowControllerTests)
- (void)pb_window_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler;
@end

@implementation NSAlert (WindowControllerTests)

- (void)pb_window_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler
{
	self.suppressionButton.state = PBWindowAlertSuppressionState;
	handler(PBWindowAlertResponse);
}

@end

@interface NSWorkspace (WindowControllerTests)
- (void)pb_window_openURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration completionHandler:(void (^)(NSRunningApplication *_Nullable app, NSError *_Nullable error))completionHandler;
- (void)pb_window_activateFileViewerSelectingURLs:(NSArray<NSURL *> *)fileURLs;
@end

@implementation NSWorkspace (WindowControllerTests)

- (void)pb_window_openURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration completionHandler:(void (^)(NSRunningApplication *_Nullable app, NSError *_Nullable error))completionHandler
{
	PBWindowWorkspaceOpenCount++;
	completionHandler(nil, nil);
}

- (void)pb_window_activateFileViewerSelectingURLs:(NSArray<NSURL *> *)fileURLs
{
	PBWindowWorkspaceRevealCount++;
}

@end

@interface NSDocumentController (WindowControllerTests)
- (void)pb_window_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display completionHandler:(void (^)(NSDocument *_Nullable document, BOOL documentWasAlreadyOpen, NSError *_Nullable error))completionHandler;
@end

@implementation NSDocumentController (WindowControllerTests)

- (void)pb_window_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display completionHandler:(void (^)(NSDocument *_Nullable document, BOOL documentWasAlreadyOpen, NSError *_Nullable error))completionHandler
{
	PBWindowDocumentOpenCount++;
	completionHandler(nil, NO, nil);
}

@end

@interface PBGitXMessageSheet (WindowControllerTests)
+ (void)pb_window_beginSheetWithMessage:(NSString *)message info:(NSString *)info windowController:(PBGitWindowController *)windowController;
+ (void)pb_window_beginSheetWithError:(NSError *)error windowController:(PBGitWindowController *)windowController;
@end

@implementation PBGitXMessageSheet (WindowControllerTests)

+ (void)pb_window_beginSheetWithMessage:(NSString *)message info:(NSString *)info windowController:(PBGitWindowController *)windowController
{
	PBWindowMessageCount++;
	PBWindowLastMessage = message;
	PBWindowLastInfo = info;
}

+ (void)pb_window_beginSheetWithError:(NSError *)error windowController:(PBGitWindowController *)windowController
{
	PBWindowErrorMessageCount++;
}

@end

@interface PBCommitHookFailedSheet (WindowControllerTests)
+ (void)pb_window_beginWithMessageText:(NSString *)message infoText:(NSString *)info commitController:(PBGitCommitController *)controller completionHandler:(RJSheetCompletionHandler)handler;
@end

@implementation PBCommitHookFailedSheet (WindowControllerTests)

+ (void)pb_window_beginWithMessageText:(NSString *)message infoText:(NSString *)info commitController:(PBGitCommitController *)controller completionHandler:(RJSheetCompletionHandler)handler
{
	PBWindowHookCount++;
	handler(NSNull.null, PBWindowHookResponse);
}

@end

@interface PBDiffWindowController (WindowControllerTests)
+ (void)pb_window_showDiff:(NSString *)diff;
+ (void)pb_window_showDiffWindowWithFiles:(nullable NSArray *)filePaths fromCommit:(PBGitCommit *)startCommit diffCommit:(nullable PBGitCommit *)diffCommit;
@end

@implementation PBDiffWindowController (WindowControllerTests)

+ (void)pb_window_showDiff:(NSString *)diff
{
	PBWindowDiffCount++;
}

+ (void)pb_window_showDiffWindowWithFiles:(NSArray *)filePaths fromCommit:(PBGitCommit *)startCommit diffCommit:(PBGitCommit *)diffCommit
{
	PBWindowStashDiffCount++;
}

@end

@interface PBTerminalUtil (WindowControllerTests)
+ (void)pb_window_runCommand:(NSString *)command inDirectory:(NSURL *)directory;
@end

@implementation PBTerminalUtil (WindowControllerTests)

+ (void)pb_window_runCommand:(NSString *)command inDirectory:(NSURL *)directory
{
	PBWindowTerminalCount++;
	PBWindowLastTerminalCommand = command;
	PBWindowLastTerminalDirectory = directory;
}

@end

@interface PBAutoFetchManager (WindowControllerTests)
- (void)pb_window_recordManualFetchSucceededForRepositoryURL:(NSURL *)repositoryURL;
@end

@implementation PBAutoFetchManager (WindowControllerTests)

- (void)pb_window_recordManualFetchSucceededForRepositoryURL:(NSURL *)repositoryURL
{
	PBWindowManualFetchCount++;
}

@end

@interface PBWindowSubmodule : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) GTRepository *parentRepository;
@end
@implementation PBWindowSubmodule
@end

@interface PBCommitIndexSpy : PBGitIndex
@property (nonatomic, copy) NSArray<PBChangedFile *> *testChanges;
@property (nonatomic, copy, nullable) NSString *prepareMessage;
@property (nonatomic, copy, nullable) NSString *lastCommitMessage;
@property (nonatomic) BOOL lastCommitVerification;
@property (nonatomic) NSUInteger refreshCount;
@property (nonatomic) NSUInteger refreshStatCacheCount;
@property (nonatomic) NSUInteger prepareCount;
@property (nonatomic) NSUInteger commitCount;
@property (nonatomic) NSUInteger stageCount;
@property (nonatomic) NSUInteger unstageCount;
@property (nonatomic) NSUInteger discardCount;
@property (nonatomic, copy) NSArray<PBChangedFile *> *lastFiles;
@end

@implementation PBCommitIndexSpy

- (NSArray<PBChangedFile *> *)indexChanges
{
	return self.testChanges ?: @[];
}
- (void)refresh
{
	self.refreshCount++;
}
- (void)refreshStatCache
{
	self.refreshStatCacheCount++;
}
- (NSString *)createPrepareCommitMessage
{
	self.prepareCount++;
	return self.prepareMessage;
}
- (void)commitWithMessage:(NSString *)commitMessage andVerify:(BOOL)doVerify
{
	self.commitCount++;
	self.lastCommitMessage = commitMessage;
	self.lastCommitVerification = doVerify;
}
- (BOOL)stageFiles:(NSArray<PBChangedFile *> *)stageFiles
{
	self.stageCount++;
	self.lastFiles = stageFiles;
	return YES;
}
- (BOOL)unstageFiles:(NSArray<PBChangedFile *> *)unstageFiles
{
	self.unstageCount++;
	self.lastFiles = unstageFiles;
	return YES;
}
- (void)discardChangesForFiles:(NSArray<PBChangedFile *> *)discardFiles
{
	self.discardCount++;
	self.lastFiles = discardFiles;
}

@end

@interface PBCommitDraggingInfo : NSObject
@property (nonatomic, strong) NSPasteboard *testPasteboard;
@property (nonatomic, weak, nullable) id testSource;
@end

@implementation PBCommitDraggingInfo
- (NSPasteboard *)draggingPasteboard
{
	return self.testPasteboard;
}
- (id)draggingSource
{
	return self.testSource;
}
@end

@interface PBWindowRepositorySpy : PBGitRepository
@property (nonatomic, strong) NSMutableArray<NSString *> *operations;
@property (nonatomic, copy, nullable) NSString *failingOperation;
@property (nonatomic, strong) NSError *testError;
@property (nonatomic, copy) NSArray<NSString *> *testRemotes;
@property (nonatomic, strong, nullable) PBGitRef *trackingRef;
@property (nonatomic, strong, nullable) PBWindowSubmodule *testSubmodule;
@property (nonatomic, copy, nullable) NSURL *testWorkingDirectoryURL;
@property (nonatomic) BOOL testBare;
@property (nonatomic, strong, nullable) PBCommitIndexSpy *testIndex;
@property (nonatomic) BOOL interceptIgnore;
@property (nonatomic) BOOL ignoreSucceeds;
@property (nonatomic) BOOL interceptHook;
@property (nonatomic) BOOL testHookExists;
@property (nonatomic) NSUInteger reloadRefsCount;
@end

@implementation PBWindowRepositorySpy

- (BOOL)recordOperation:(NSString *)operation error:(NSError **)error
{
	[self.operations addObject:operation];
	BOOL success = ![self.failingOperation isEqualToString:operation];
	if (!success && error) *error = self.testError;
	return success;
}

- (NSURL *)workingDirectoryURL
{
	return self.testWorkingDirectoryURL ?: super.workingDirectoryURL;
}
- (BOOL)isBareRepository
{
	return self.testBare;
}
- (PBGitIndex *)index
{
	return self.testIndex ?: super.index;
}
- (void)reloadRefs
{
	self.reloadRefsCount++;
	[super reloadRefs];
}
- (NSArray<NSString *> *)remotes
{
	return self.testRemotes;
}
- (PBGitRef *)remoteRefForBranch:(PBGitRef *)branch error:(NSError **)error
{
	return self.trackingRef;
}
- (GTSubmodule *)submoduleAtPath:(NSString *)path error:(NSError **)error
{
	return (GTSubmodule *)self.testSubmodule;
}
- (BOOL)ignoreFilePaths:(NSArray<NSString *> *)filePaths error:(NSError **)error
{
	if (!self.interceptIgnore) return [super ignoreFilePaths:filePaths error:error];
	[self.operations addObject:[NSString stringWithFormat:@"ignore:%@", [filePaths componentsJoinedByString:@","]]];
	if (!self.ignoreSucceeds && error) *error = self.testError;
	return self.ignoreSucceeds;
}
- (BOOL)hookExists:(NSString *)name
{
	return self.interceptHook ? self.testHookExists : [super hookExists:name];
}
- (BOOL)addRemote:(NSString *)remoteName withURL:(NSString *)URLString error:(NSError **)error
{
	return [self recordOperation:@"addRemote" error:error];
}
- (BOOL)fetchRemoteForRef:(PBGitRef *)ref error:(NSError **)error
{
	return [self recordOperation:@"fetch" error:error];
}
- (BOOL)pullBranch:(PBGitRef *)branchRef fromRemote:(PBGitRef *)remoteRef rebase:(BOOL)rebase error:(NSError **)error
{
	return [self recordOperation:(rebase ? @"pullRebase" : @"pull") error:error];
}
- (BOOL)pushBranch:(PBGitRef *)branchRef toRemote:(PBGitRef *)remoteRef error:(NSError **)error
{
	return [self recordOperation:@"push" error:error];
}
- (BOOL)checkoutRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self recordOperation:@"checkout" error:error];
}
- (BOOL)mergeWithRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self recordOperation:@"merge" error:error];
}
- (BOOL)rebaseBranch:(id<PBGitRefish>)branch onRefish:(id<PBGitRefish>)upstream error:(NSError **)error
{
	return [self recordOperation:@"rebase" error:error];
}
- (BOOL)cherryPickRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self recordOperation:@"cherryPick" error:error];
}
- (BOOL)resetRefish:(GTRepositoryResetType)mode to:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self recordOperation:@"reset" error:error];
}
- (BOOL)deleteRef:(PBGitRef *)ref error:(NSError **)error
{
	return [self recordOperation:@"delete" error:error];
}
- (BOOL)createBranch:(NSString *)branchName atRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self recordOperation:@"createBranch" error:error];
}
- (BOOL)createTag:(NSString *)tagName message:(NSString *)message atRefish:(id<PBGitRefish>)ref error:(NSError **)error
{
	return [self recordOperation:@"createTag" error:error];
}
- (BOOL)stashSaveWithKeepIndex:(BOOL)keepIndex error:(NSError **)error
{
	return [self recordOperation:(keepIndex ? @"stashSaveKeep" : @"stashSave") error:error];
}
- (BOOL)stashPop:(PBGitStash *)stash error:(NSError **)error
{
	return [self recordOperation:@"stashPop" error:error];
}
- (BOOL)stashApply:(PBGitStash *)stash error:(NSError **)error
{
	return [self recordOperation:@"stashApply" error:error];
}
- (BOOL)stashDrop:(PBGitStash *)stash error:(NSError **)error
{
	return [self recordOperation:@"stashDrop" error:error];
}
- (NSString *)performDiff:(PBGitCommit *)startCommit against:(PBGitCommit *)diffCommit forFiles:(NSArray<NSString *> *)filePaths
{
	[self.operations addObject:@"diff"];
	return @"characterized diff";
}

@end

@interface PBWindowHistorySpy : PBGitHistoryController
@property (nonatomic, strong) PBCommitList *testCommitList;
@end

@implementation PBWindowHistorySpy
- (PBCommitList *)commitList
{
	return self.testCommitList;
}
- (BOOL)singleCommitSelected
{
	return self.selectedCommits.count == 1;
}
@end

@interface PBWindowOutlineView : NSOutlineView
@property (nonatomic, strong, nullable) id testItem;
@end
@implementation PBWindowOutlineView
- (id)itemAtRow:(NSInteger)row
{
	return self.testItem;
}
@end

@interface PBWindowSidebarSpy : PBGitSidebarController
@property (nonatomic, strong) PBWindowOutlineView *testSourceView;
@property (nonatomic, strong) PBSourceViewItem *testRemotes;
@property (nonatomic) NSUInteger stageSelectionCount;
@property (nonatomic) NSUInteger branchSelectionCount;
@end

@implementation PBWindowSidebarSpy
- (NSOutlineView *)sourceView
{
	return self.testSourceView;
}
- (PBSourceViewItem *)remotes
{
	return self.testRemotes;
}
- (void)selectStage
{
	self.stageSelectionCount++;
}
- (void)selectCurrentBranch
{
	self.branchSelectionCount++;
}
@end

@interface PBWindowContentSpy : PBViewController
@property (nonatomic, strong) NSTextField *testFirstResponder;
@property (nonatomic) NSUInteger updateCount;
@property (nonatomic) NSUInteger refreshCount;
@property (nonatomic) NSUInteger closeCount;
@end

@implementation PBWindowContentSpy
- (instancetype)init
{
	self = [super initWithNibName:nil bundle:nil];
	if (!self) return nil;
	self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	_testFirstResponder = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];
	[self.view addSubview:_testFirstResponder];
	return self;
}
- (NSResponder *)firstResponder
{
	return self.testFirstResponder;
}
- (void)updateView
{
	self.updateCount++;
}
- (void)refresh:(id)sender
{
	self.refreshCount++;
}
- (void)closeView
{
	self.closeCount++;
}
@end

@interface PBWindowCommitControllerSpy : PBGitCommitController
@property (nonatomic) NSUInteger forceCommitCount;
@end
@implementation PBWindowCommitControllerSpy
- (IBAction)forceCommit:(id)sender
{
	self.forceCommitCount++;
}
@end

@interface PBWindowTestWindow : NSWindow
@property (nonatomic, strong, nullable) NSResponder *testFirstResponder;
@end

@implementation PBWindowTestWindow
- (NSResponder *)firstResponder
{
	return self.testFirstResponder ?: super.firstResponder;
}
@end

@interface PBWindowControllerSpy : PBGitWindowController
@property (nonatomic, strong) PBWindowRepositorySpy *fixedRepository;
@property (nonatomic, strong) NSMutableArray<NSError *> *shownErrors;
@property (nonatomic, strong) NSMutableArray<NSAlert *> *confirmations;
@property (nonatomic) BOOL shouldConfirm;
@property (nonatomic) BOOL useRealConfirmation;
@property (nonatomic) BOOL useRealErrorPresentation;
@property (nonatomic) BOOL interceptRemoteRouting;
@property (nonatomic) NSUInteger fetchRouteCount;
@property (nonatomic) NSUInteger pullRouteCount;
@property (nonatomic) NSUInteger pushRouteCount;
@property (nonatomic) BOOL lastPullRebase;
@property (nonatomic) BOOL lastPushRequiresConfirmation;
@property (nonatomic, strong, nullable) PBGitRef *lastBranch;
@property (nonatomic, strong, nullable) PBGitRef *lastRemote;
@property (nonatomic, copy, nullable) NSArray<NSURL *> *openedURLs;
@property (nonatomic, copy, nullable) NSArray<NSURL *> *revealedURLs;
@property (nonatomic) NSUInteger refreshCount;
@property (nonatomic) NSUInteger synchronizeCount;
@end

@implementation PBWindowControllerSpy

- (instancetype)initWithRepository:(PBWindowRepositorySpy *)repository
{
	self = [super initWithWindow:[[PBWindowTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
																	   styleMask:NSWindowStyleMaskTitled
																		 backing:NSBackingStoreBuffered
																		   defer:NO]];
	if (!self) return nil;
	_fixedRepository = repository;
	_shownErrors = [NSMutableArray array];
	_confirmations = [NSMutableArray array];
	_shouldConfirm = YES;
	return self;
}

- (PBGitRepository *)repository
{
	return self.fixedRepository;
}
- (void)showErrorSheet:(NSError *)error
{
	if (self.useRealErrorPresentation) return [super showErrorSheet:error];
	[self.shownErrors addObject:error ?: self.fixedRepository.testError];
}
- (BOOL)confirmDialog:(NSAlert *)alert suppressionIdentifier:(NSString *)identifier forAction:(void (^)(void))actionBlock
{
	if (self.useRealConfirmation) return [super confirmDialog:alert suppressionIdentifier:identifier forAction:actionBlock];
	[self.confirmations addObject:alert];
	if (self.shouldConfirm) actionBlock();
	return self.shouldConfirm;
}
- (void)performFetchForRef:(PBGitRef *)ref
{
	if (!self.interceptRemoteRouting) return [super performFetchForRef:ref];
	self.fetchRouteCount++;
	self.lastRemote = ref;
}
- (void)performPullForBranch:(PBGitRef *)branchRef remote:(PBGitRef *)remoteRef rebase:(BOOL)rebase
{
	if (!self.interceptRemoteRouting) return [super performPullForBranch:branchRef remote:remoteRef rebase:rebase];
	self.pullRouteCount++;
	self.lastBranch = branchRef;
	self.lastRemote = remoteRef;
	self.lastPullRebase = rebase;
}
- (void)performPushForBranch:(PBGitRef *)branchRef toRemote:(PBGitRef *)remoteRef
{
	if (!self.interceptRemoteRouting) return [super performPushForBranch:branchRef toRemote:remoteRef];
	self.pushRouteCount++;
	self.lastBranch = branchRef;
	self.lastRemote = remoteRef;
}
- (void)performPushForBranch:(PBGitRef *)branchRef
					toRemote:(PBGitRef *)remoteRef
		requiresConfirmation:(BOOL)requiresConfirmation
{
	if (!self.interceptRemoteRouting) {
		return [super performPushForBranch:branchRef toRemote:remoteRef requiresConfirmation:requiresConfirmation];
	}
	self.pushRouteCount++;
	self.lastBranch = branchRef;
	self.lastRemote = remoteRef;
	self.lastPushRequiresConfirmation = requiresConfirmation;
}
- (void)openURLs:(NSArray<NSURL *> *)fileURLs
{
	self.openedURLs = fileURLs;
}
- (void)revealURLsInFinder:(NSArray<NSURL *> *)fileURLs
{
	self.revealedURLs = fileURLs;
}
- (IBAction)refresh:(id)sender
{
	self.refreshCount++;
}
- (void)synchronizeWindowTitleWithDocumentName
{
	self.synchronizeCount++;
}

@end

@interface WindowControllerTests : XCTestCase
@property (nonatomic, copy) NSURL *repositoryURL;
@property (nonatomic, copy) NSURL *remoteURL;
@property (nonatomic, strong) PBWindowRepositorySpy *repository;
@property (nonatomic, strong) PBWindowControllerSpy *controller;
@property (nonatomic, strong) PBGitRef *branchRef;
@property (nonatomic, strong) PBGitRef *remoteRef;
@property (nonatomic, strong) PBGitRef *remoteBranchRef;
@property (nonatomic, strong) PBGitRef *tagRef;
@property (nonatomic, strong) PBGitCommit *headCommit;
@property (nonatomic, strong) PBGitStash *stash;
@end

@implementation WindowControllerTests

+ (void)setUp
{
	[super setUp];
	PBSwapClassMethods(PBRemoteProgressSheet.class, @selector(progressSheetWithTitle:description:windowController:), @selector(pb_window_progressSheetWithTitle:description:windowController:));
	PBSwapClassMethods(PBAddRemoteSheet.class, @selector(beginSheetWithWindowController:completionHandler:), @selector(pb_window_beginSheetWithWindowController:completionHandler:));
	PBSwapClassMethods(PBCreateBranchSheet.class, @selector(beginSheetWithRefish:windowController:completionHandler:), @selector(pb_window_beginSheetWithRefish:windowController:completionHandler:));
	PBSwapClassMethods(PBCreateTagSheet.class, @selector(beginSheetWithRefish:windowController:completionHandler:), @selector(pb_window_beginSheetWithRefish:windowController:completionHandler:));
	PBSwapInstanceMethods(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:), @selector(pb_window_beginSheetModalForWindow:completionHandler:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(openURL:configuration:completionHandler:), @selector(pb_window_openURL:configuration:completionHandler:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(activateFileViewerSelectingURLs:), @selector(pb_window_activateFileViewerSelectingURLs:));
	PBSwapInstanceMethods(NSDocumentController.class, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(pb_window_openDocumentWithContentsOfURL:display:completionHandler:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithMessage:info:windowController:), @selector(pb_window_beginSheetWithMessage:info:windowController:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithError:windowController:), @selector(pb_window_beginSheetWithError:windowController:));
	PBSwapClassMethods(PBCommitHookFailedSheet.class, @selector(beginWithMessageText:infoText:commitController:completionHandler:), @selector(pb_window_beginWithMessageText:infoText:commitController:completionHandler:));
	PBSwapClassMethods(PBDiffWindowController.class, @selector(showDiff:), @selector(pb_window_showDiff:));
	PBSwapClassMethods(PBDiffWindowController.class, @selector(showDiffWindowWithFiles:fromCommit:diffCommit:), @selector(pb_window_showDiffWindowWithFiles:fromCommit:diffCommit:));
	PBSwapClassMethods(PBTerminalUtil.class, @selector(runCommand:inDirectory:), @selector(pb_window_runCommand:inDirectory:));
	PBSwapInstanceMethods(PBAutoFetchManager.class, @selector(recordManualFetchSucceededForRepositoryURL:), @selector(pb_window_recordManualFetchSucceededForRepositoryURL:));
	PBSwapClassMethods(PBTask.class, @selector(taskWithLaunchPath:arguments:inDirectory:), @selector(pb_window_taskWithLaunchPath:arguments:inDirectory:));
	PBSwapInstanceMethods(NSFileManager.class, @selector(trashItemAtURL:resultingItemURL:error:), @selector(pb_window_trashItemAtURL:resultingItemURL:error:));
	PBSwapInstanceMethods(GTConfiguration.class, @selector(stringForKey:), @selector(pb_window_stringForKey:));
}

+ (void)tearDown
{
	PBSwapInstanceMethods(GTConfiguration.class, @selector(stringForKey:), @selector(pb_window_stringForKey:));
	PBSwapInstanceMethods(NSFileManager.class, @selector(trashItemAtURL:resultingItemURL:error:), @selector(pb_window_trashItemAtURL:resultingItemURL:error:));
	PBSwapClassMethods(PBTask.class, @selector(taskWithLaunchPath:arguments:inDirectory:), @selector(pb_window_taskWithLaunchPath:arguments:inDirectory:));
	PBSwapInstanceMethods(PBAutoFetchManager.class, @selector(recordManualFetchSucceededForRepositoryURL:), @selector(pb_window_recordManualFetchSucceededForRepositoryURL:));
	PBSwapClassMethods(PBTerminalUtil.class, @selector(runCommand:inDirectory:), @selector(pb_window_runCommand:inDirectory:));
	PBSwapClassMethods(PBDiffWindowController.class, @selector(showDiffWindowWithFiles:fromCommit:diffCommit:), @selector(pb_window_showDiffWindowWithFiles:fromCommit:diffCommit:));
	PBSwapClassMethods(PBDiffWindowController.class, @selector(showDiff:), @selector(pb_window_showDiff:));
	PBSwapClassMethods(PBCommitHookFailedSheet.class, @selector(beginWithMessageText:infoText:commitController:completionHandler:), @selector(pb_window_beginWithMessageText:infoText:commitController:completionHandler:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithError:windowController:), @selector(pb_window_beginSheetWithError:windowController:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithMessage:info:windowController:), @selector(pb_window_beginSheetWithMessage:info:windowController:));
	PBSwapInstanceMethods(NSDocumentController.class, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(pb_window_openDocumentWithContentsOfURL:display:completionHandler:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(activateFileViewerSelectingURLs:), @selector(pb_window_activateFileViewerSelectingURLs:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(openURL:configuration:completionHandler:), @selector(pb_window_openURL:configuration:completionHandler:));
	PBSwapInstanceMethods(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:), @selector(pb_window_beginSheetModalForWindow:completionHandler:));
	PBSwapClassMethods(PBCreateTagSheet.class, @selector(beginSheetWithRefish:windowController:completionHandler:), @selector(pb_window_beginSheetWithRefish:windowController:completionHandler:));
	PBSwapClassMethods(PBCreateBranchSheet.class, @selector(beginSheetWithRefish:windowController:completionHandler:), @selector(pb_window_beginSheetWithRefish:windowController:completionHandler:));
	PBSwapClassMethods(PBAddRemoteSheet.class, @selector(beginSheetWithWindowController:completionHandler:), @selector(pb_window_beginSheetWithWindowController:completionHandler:));
	PBSwapClassMethods(PBRemoteProgressSheet.class, @selector(progressSheetWithTitle:description:windowController:), @selector(pb_window_progressSheetWithTitle:description:windowController:));
	[super tearDown];
}

- (void)setUp
{
	[super setUp];
	[NSApplication sharedApplication];
	[PBGitDefaults resetAllDialogWarnings];
	[NSUserDefaults.standardUserDefaults setObject:@NO forKey:@"PBRefreshOnApplicationFocus"];

	NSString *name = [NSString stringWithFormat:@"GitXWindowController-%@", NSUUID.UUID.UUIDString];
	self.repositoryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	self.remoteURL = [self.repositoryURL URLByAppendingPathExtension:@"remote.git"];
	[NSFileManager.defaultManager createDirectoryAtURL:self.repositoryURL withIntermediateDirectories:YES attributes:nil error:NULL];
	[self git:@[ @"init", @"--quiet", @"--initial-branch=main" ] directory:self.repositoryURL];
	[self git:@[ @"config", @"user.name", @"GitX Tests" ] directory:self.repositoryURL];
	[self git:@[ @"config", @"user.email", @"gitx-tests@example.invalid" ] directory:self.repositoryURL];
	[@"initial\n" writeToURL:[self.repositoryURL URLByAppendingPathComponent:@"tracked.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self git:@[ @"add", @"--all" ] directory:self.repositoryURL];
	[self git:@[ @"commit", @"--quiet", @"-m", @"initial" ] directory:self.repositoryURL];
	[self git:@[ @"branch", @"feature" ] directory:self.repositoryURL];
	[self git:@[ @"tag", @"-a", @"v1", @"-m", @"annotated tag" ] directory:self.repositoryURL];
	[self git:@[ @"init", @"--bare", @"--quiet", self.remoteURL.path ] directory:self.repositoryURL];
	[self git:@[ @"remote", @"add", @"origin", self.remoteURL.path ] directory:self.repositoryURL];
	[self git:@[ @"push", @"--quiet", @"--set-upstream", @"origin", @"main" ] directory:self.repositoryURL];
	[@"stash\n" writeToURL:[self.repositoryURL URLByAppendingPathComponent:@"stash.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self git:@[ @"add", @"stash.txt" ] directory:self.repositoryURL];
	[self git:@[ @"stash", @"push", @"--quiet", @"-m", @"window stash" ] directory:self.repositoryURL];

	NSError *error = nil;
	self.repository = [[PBWindowRepositorySpy alloc] initWithURL:self.repositoryURL error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);
	self.repository.operations = [NSMutableArray array];
	self.repository.testError = [NSError errorWithDomain:@"WindowControllerTests" code:41 userInfo:@{NSLocalizedDescriptionKey : @"expected failure"}];
	self.repository.testRemotes = @[ @"origin", @"backup" ];
	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	self.branchRef = [self.repository refForName:@"main"];
	self.remoteBranchRef = [self.repository refForName:@"origin/main"];
	self.remoteRef = [PBGitRef refFromString:@"refs/remotes/origin"];
	self.tagRef = [self.repository refForName:@"v1"];
	self.repository.trackingRef = self.remoteBranchRef;
	NSDate *historyDeadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
	while (self.repository.revisionList.commits.count == 0 && historyDeadline.timeIntervalSinceNow > 0) {
		[self pumpRunLoopFor:0.02];
	}
	GTOID *headOID = self.repository.headOID;
	for (PBGitCommit *commit in self.repository.revisionList.commits) {
		if ([commit.OID isEqual:headOID]) {
			self.headCommit = commit;
			break;
		}
	}
	XCTAssertNotNil(self.headCommit);
	self.stash = self.repository.stashes.firstObject;
	self.controller = [[PBWindowControllerSpy alloc] initWithRepository:self.repository];

	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertSuppressionState = NSControlStateValueOff;
	PBWindowAddRemoteResponse = NSModalResponseCancel;
	PBWindowCreateBranchResponse = NSModalResponseCancel;
	PBWindowCreateTagResponse = NSModalResponseCancel;
	PBWindowHookResponse = NSModalResponseCancel;
	PBWindowWorkspaceOpenCount = 0;
	PBWindowWorkspaceRevealCount = 0;
	PBWindowDocumentOpenCount = 0;
	PBWindowMessageCount = 0;
	PBWindowErrorMessageCount = 0;
	PBWindowHookCount = 0;
	PBWindowDiffCount = 0;
	PBWindowStashDiffCount = 0;
	PBWindowTerminalCount = 0;
	PBWindowManualFetchCount = 0;
	PBWindowLastProgressTitle = nil;
	PBWindowLastProgressDescription = nil;
	PBWindowLastMessage = nil;
	PBWindowLastInfo = nil;
	PBWindowLastTerminalCommand = nil;
	PBWindowLastTerminalDirectory = nil;
	PBWindowUseSnapshotTaskFake = NO;
	PBWindowSnapshotData = nil;
	PBWindowSnapshotError = nil;
	PBWindowTrashSucceeds = YES;
	PBWindowTrashCount = 0;
	PBWindowConfigurationMissingIdentity = NO;
	PBWindowRunProgressInBackground = NO;
	PBWindowProgressExpectation = nil;

	PBWindowAddRemoteTestSheet = [[PBWindowAddRemoteSheet alloc] initWithWindow:nil];
	PBWindowAddRemoteTestSheet.testRemoteName = [NSTextField labelWithString:NSLocalizedString(@"origin", nil)];
	PBWindowAddRemoteTestSheet.testRemoteURL = [NSTextField labelWithString:self.remoteURL.path];
	PBWindowCreateBranchTestSheet = [[PBWindowCreateBranchSheet alloc] initWithWindow:nil];
	PBWindowCreateBranchTestSheet.testBranchNameField = [NSTextField labelWithString:NSLocalizedString(@"characterized", nil)];
	PBWindowCreateBranchTestSheet.selectedRef = self.branchRef;
	PBWindowCreateTagTestSheet = [[PBWindowCreateTagSheet alloc] initWithWindow:nil];
	PBWindowCreateTagTestSheet.testTagNameField = [NSTextField labelWithString:NSLocalizedString(@"characterized-tag", nil)];
	PBWindowCreateTagTestSheet.testTagMessageText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 40)];
	PBWindowCreateTagTestSheet.testTagMessageText.string = NSLocalizedString(@"tag message", nil);
	PBWindowCreateTagTestSheet.targetRefish = self.branchRef;
}

- (void)tearDown
{
	[self.controller.window orderOut:nil];
	[self.controller.window close];
	[self.repository.revisionList cleanup];
	self.controller = nil;
	self.repository = nil;
	PBWindowAddRemoteTestSheet = nil;
	PBWindowCreateBranchTestSheet = nil;
	PBWindowCreateTagTestSheet = nil;
	PBWindowUseSnapshotTaskFake = NO;
	PBWindowSnapshotData = nil;
	PBWindowSnapshotError = nil;
	[NSFileManager.defaultManager removeItemAtURL:self.repositoryURL error:NULL];
	[NSFileManager.defaultManager removeItemAtURL:self.remoteURL error:NULL];
	[PBGitDefaults resetAllDialogWarnings];
	[super tearDown];
}

- (NSString *)git:(NSArray<NSString *> *)arguments directory:(NSURL *)directory
{
	NSError *error = nil;
	NSString *output = [PBTask outputForCommand:@"/usr/bin/git" arguments:arguments inDirectory:directory.path error:&error];
	XCTAssertNotNil(output, @"git %@ failed: %@", arguments, error);
	return output ?: @"";
}

- (NSMenuItem *)menuItemWithObject:(nullable id)object
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Test", nil) action:nil keyEquivalent:@""];
	item.representedObject = object;
	return item;
}

- (PBGitCommitController *)loadedCommitControllerWithIndex:(PBCommitIndexSpy *)index
{
	self.repository.testIndex = index;
	PBGitCommitController *controller = [[PBGitCommitController alloc] initWithRepository:self.repository superController:self.controller];
	NSView *view = controller.view;
	view.frame = self.controller.window.contentView.bounds;
	[self.controller.window.contentView addSubview:view];
	return controller;
}

- (PBChangedFile *)changedFileWithPath:(NSString *)path
								status:(PBChangedFileStatus)status
					  hasStagedChanges:(BOOL)hasStagedChanges
					hasUnstagedChanges:(BOOL)hasUnstagedChanges
{
	PBChangedFile *file = [[PBChangedFile alloc] initWithPath:path];
	file.status = status;
	file.hasStagedChanges = hasStagedChanges;
	file.hasUnstagedChanges = hasUnstagedChanges;
	return file;
}

- (void)setCommitFiles:(NSArray<PBChangedFile *> *)files controller:(PBGitCommitController *)controller
{
	self.repository.testIndex.testChanges = files;
	for (NSString *key in @[ @"unstagedFilesController", @"stagedFilesController", @"trackedFilesController" ]) {
		NSArrayController *arrayController = [controller valueForKey:key];
		[arrayController setContent:files];
		[arrayController rearrangeObjects];
	}
}

- (NSMenuItem *)commitMenuItemWithAction:(SEL)action table:(NSTableView *)table
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Test", nil) action:action keyEquivalent:@""];
	[table.menu addItem:item];
	return item;
}

- (void)pumpRunLoopFor:(NSTimeInterval)duration
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
	while ([deadline timeIntervalSinceNow] > 0) {
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	}
}

- (void)testCommitControllerNibLifecycleRefreshAndRemoteSelection
{
	PBCommitIndexSpy *index = [[PBCommitIndexSpy alloc] initWithRepository:self.repository];
	PBGitCommitController *controller = [self loadedCommitControllerWithIndex:index];
	PBCommitMessageView *messageView = [controller valueForKey:@"commitMessageView"];
	NSTableView *unstagedTable = [controller valueForKey:@"unstagedTable"];
	NSTableView *stagedTable = [controller valueForKey:@"stagedTable"];
	NSButton *pushAfterCommitButton = [controller valueForKey:@"pushAfterCommitButton"];
	NSPopUpButton *pushRemotePopUpButton = [controller valueForKey:@"pushRemotePopUpButton"];

	XCTAssertEqual(messageView.repository, self.repository);
	XCTAssertEqual((id)messageView.delegate, controller);
	XCTAssertEqualObjects(messageView.accessibilityIdentifier, @"CommitMessage");
	XCTAssertEqualObjects(unstagedTable.accessibilityIdentifier, @"UnstagedFiles");
	XCTAssertEqualObjects(stagedTable.accessibilityIdentifier, @"StagedFiles");
	XCTAssertEqualObjects(pushAfterCommitButton.accessibilityIdentifier, @"PushAfterCommit");
	XCTAssertEqualObjects(pushRemotePopUpButton.accessibilityIdentifier, @"PushRemote");
	XCTAssertEqual(unstagedTable.target, controller);
	XCTAssertEqual(stagedTable.target, controller);
	XCTAssertEqual(unstagedTable.doubleAction, @selector(didDoubleClickOnTable:));
	XCTAssertEqual(stagedTable.doubleAction, @selector(didDoubleClickOnTable:));
	XCTAssertTrue(unstagedTable.allowsMultipleSelection);
	XCTAssertTrue(stagedTable.allowsMultipleSelection);
	XCTAssertNotEqual(unstagedTable.menu, stagedTable.menu);
	XCTAssertEqualObjects([controller firstResponder], messageView);
	XCTAssertEqualObjects([controller index], index);
	NSView *messagePane = messageView.enclosingScrollView.superview;
	NSSplitView *composerSplitView = (NSSplitView *)messagePane.superview;
	XCTAssertTrue([composerSplitView isKindOfClass:NSSplitView.class]);
	XCTAssertFalse(composerSplitView.isVertical);
	XCTAssertEqualObjects(composerSplitView.autosaveName, @"CommitComposer");
	XCTAssertEqual(composerSplitView.subviews.count, (NSUInteger)2);
	NSSplitView *fileSplitView = (NSSplitView *)composerSplitView.subviews.firstObject;
	XCTAssertTrue(fileSplitView.isVertical);
	XCTAssertEqual(fileSplitView.subviews.count, (NSUInteger)2);
	XCTAssertEqualObjects(pushRemotePopUpButton.itemTitles, (@[ @"backup", @"origin" ]));
	XCTAssertEqualObjects([controller selectedPushRemoteName], @"origin");

	[pushRemotePopUpButton selectItemWithTitle:NSLocalizedString(@"backup", nil)];
	[controller reloadPushRemotes];
	XCTAssertEqualObjects([controller selectedPushRemoteName], @"backup");

	self.repository.testRemotes = @[];
	[controller reloadPushRemotes];
	XCTAssertEqualObjects(pushRemotePopUpButton.itemTitles, (@[ @"No Remotes" ]));
	XCTAssertFalse(pushRemotePopUpButton.lastItem.enabled);
	XCTAssertFalse(pushAfterCommitButton.enabled);
	XCTAssertEqual(pushAfterCommitButton.state, NSControlStateValueOff);
	XCTAssertNil([controller selectedPushRemoteName]);

	PBRepositoryUISettings *uiSettings = [[PBRepositoryUISettings alloc] initWithRepository:self.repository];
	uiSettings.pushAfterCommit = YES;
	self.repository.testRemotes = @[ @"zebra" ];
	self.repository.trackingRef = nil;
	[controller reloadPushRemotes];
	XCTAssertEqualObjects([controller selectedPushRemoteName], @"zebra");
	XCTAssertTrue(pushAfterCommitButton.enabled);
	XCTAssertEqual(pushAfterCommitButton.state, NSControlStateValueOn);

	index.refreshStatCacheCount = 0;
	[controller applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:nil]];
	XCTAssertEqual(index.refreshStatCacheCount, (NSUInteger)1);
	[NSUserDefaults.standardUserDefaults setObject:@YES forKey:@"PBRefreshOnApplicationFocus"];
	[controller applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:nil]];
	XCTAssertEqual(index.refreshStatCacheCount, (NSUInteger)1);

	NSUInteger reloadCount = self.repository.reloadRefsCount;
	NSDictionary *workingDirectoryEvent = @{kPBGitRepositoryEventTypeUserInfoKey : @(PBGitRepositoryWatcherEventTypeWorkingDirectory)};
	[controller repositoryUpdatedNotification:[NSNotification notificationWithName:PBGitRepositoryEventNotification
																			object:self.repository
																		  userInfo:workingDirectoryEvent]];
	XCTAssertEqual(index.refreshCount, (NSUInteger)1);
	XCTAssertEqual(self.repository.reloadRefsCount, reloadCount + 1);

	NSDictionary *gitDirectoryEvent = @{kPBGitRepositoryEventTypeUserInfoKey : @(PBGitRepositoryWatcherEventTypeGitDirectory)};
	[controller repositoryUpdatedNotification:[NSNotification notificationWithName:PBGitRepositoryEventNotification
																			object:self.repository
																		  userInfo:gitDirectoryEvent]];
	XCTAssertEqual(self.repository.reloadRefsCount, reloadCount + 2);

	[controller updateView];
	XCTAssertEqual(index.refreshCount, (NSUInteger)2);
	XCTAssertEqual(self.repository.reloadRefsCount, reloadCount + 3);
	[controller closeView];
}

- (void)testCommitLayoutCoordinatorHandlesIncompleteAndFreshViewHierarchies
{
	NSSplitView *outerSplitView = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
	NSTableView *unstagedTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
	NSTableView *stagedTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
	NSTextView *orphanMessage = [[NSTextView alloc] initWithFrame:NSZeroRect];
	[PBCommitLayoutCoordinator configureOuterSplitView:outerSplitView
									 commitMessageView:orphanMessage
										 unstagedTable:unstagedTable
										   stagedTable:stagedTable];

	NSTextView *message = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 100)];
	NSScrollView *messageScroll = [[NSScrollView alloc] initWithFrame:message.frame];
	messageScroll.documentView = message;
	NSView *messagePane = [[NSView alloc] initWithFrame:message.frame];
	[messagePane addSubview:messageScroll];
	NSSplitView *fileSplitView = [[NSSplitView alloc] initWithFrame:outerSplitView.bounds];
	[fileSplitView addSubview:messagePane];
	[PBCommitLayoutCoordinator configureOuterSplitView:outerSplitView
									 commitMessageView:message
										 unstagedTable:unstagedTable
										   stagedTable:stagedTable];
	XCTAssertEqual(messagePane.superview, fileSplitView);

	[outerSplitView addSubview:fileSplitView];
	NSString *autosaveKey = @"NSSplitView Subview Frames CommitComposer";
	id originalAutosaveFrames = [NSUserDefaults.standardUserDefaults objectForKey:autosaveKey];
	[NSUserDefaults.standardUserDefaults removeObjectForKey:autosaveKey];
	@try {
		[PBCommitLayoutCoordinator configureOuterSplitView:outerSplitView
										 commitMessageView:message
											 unstagedTable:unstagedTable
											   stagedTable:stagedTable];
		NSSplitView *composer = (NSSplitView *)messagePane.superview;
		XCTAssertTrue([composer isKindOfClass:NSSplitView.class]);
		XCTAssertEqualObjects(composer.autosaveName, @"CommitComposer");
		XCTAssertFalse(composer.isVertical);
		XCTAssertTrue(unstagedTable.allowsMultipleSelection);
		XCTAssertTrue(stagedTable.allowsMultipleSelection);

		[PBCommitLayoutCoordinator configureOuterSplitView:outerSplitView
										 commitMessageView:message
											 unstagedTable:unstagedTable
											   stagedTable:stagedTable];
		XCTAssertEqual(messagePane.superview, composer);

		[NSUserDefaults.standardUserDefaults setObject:@[] forKey:autosaveKey];
		NSSplitView *savedOuterSplitView = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
		NSTextView *savedMessage = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 100)];
		NSScrollView *savedMessageScroll = [[NSScrollView alloc] initWithFrame:savedMessage.frame];
		savedMessageScroll.documentView = savedMessage;
		NSView *savedMessagePane = [[NSView alloc] initWithFrame:savedMessage.frame];
		[savedMessagePane addSubview:savedMessageScroll];
		NSSplitView *savedFileSplitView = [[NSSplitView alloc] initWithFrame:savedOuterSplitView.bounds];
		[savedFileSplitView addSubview:savedMessagePane];
		[savedOuterSplitView addSubview:savedFileSplitView];
		[PBCommitLayoutCoordinator configureOuterSplitView:savedOuterSplitView
										 commitMessageView:savedMessage
											 unstagedTable:unstagedTable
											   stagedTable:stagedTable];
		XCTAssertEqualObjects(((NSSplitView *)savedMessagePane.superview).autosaveName, @"CommitComposer");
	} @finally {
		if (originalAutosaveFrames)
			[NSUserDefaults.standardUserDefaults setObject:originalAutosaveFrames forKey:autosaveKey];
		else
			[NSUserDefaults.standardUserDefaults removeObjectForKey:autosaveKey];
	}
}

- (void)testCommitControllerSubmissionValidationAndNotificationTransitions
{
	PBCommitIndexSpy *index = [[PBCommitIndexSpy alloc] initWithRepository:self.repository];
	PBGitCommitController *controller = [self loadedCommitControllerWithIndex:index];
	PBCommitMessageView *messageView = [controller valueForKey:@"commitMessageView"];
	NSButton *pushAfterCommitButton = [controller valueForKey:@"pushAfterCommitButton"];
	NSPopUpButton *pushRemotePopUpButton = [controller valueForKey:@"pushRemotePopUpButton"];
	NSButton *commitButton = [controller valueForKey:@"commitButton"];
	PBChangedFile *staged = [self changedFileWithPath:@"tracked.txt" status:MODIFIED hasStagedChanges:YES hasUnstagedChanges:NO];

	[self setCommitFiles:@[ staged ] controller:controller];
	messageView.string = NSLocalizedString(@"characterized commit", nil);
	NSURL *mergeHeadURL = [self.repository.gitURL URLByAppendingPathComponent:@"MERGE_HEAD"];
	[@"merge\n" writeToURL:mergeHeadURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[controller commit:self];
	XCTAssertEqual(index.commitCount, (NSUInteger)0);
	XCTAssertEqualObjects(PBWindowLastMessage, @"Cannot commit merges");
	[NSFileManager.defaultManager removeItemAtURL:mergeHeadURL error:NULL];

	[self setCommitFiles:@[] controller:controller];
	[controller commit:self];
	XCTAssertEqualObjects(PBWindowLastMessage, @"No changes to commit");

	[self setCommitFiles:@[ staged ] controller:controller];
	messageView.string = NSLocalizedString(@"no", nil);
	[controller commit:self];
	XCTAssertEqualObjects(PBWindowLastMessage, @"Missing commit message");

	[self git:@[ @"config", @"--local", @"gitx.commitMessageReplacementRules", @"([ => invalid" ] directory:self.repositoryURL];
	NSUInteger shownErrorCount = self.controller.shownErrors.count;
	messageView.string = NSLocalizedString(@"invalid replacement", nil);
	[controller commit:self];
	XCTAssertEqual(index.commitCount, (NSUInteger)0);
	XCTAssertEqual(self.controller.shownErrors.count, shownErrorCount + 1);

	[self git:@[ @"config", @"--local", @"gitx.commitMessageReplacementRules", @"^verified => transformed" ] directory:self.repositoryURL];
	messageView.string = NSLocalizedString(@"verified commit", nil);
	[controller commit:self];
	XCTAssertEqual(index.commitCount, (NSUInteger)1);
	XCTAssertEqualObjects(index.lastCommitMessage, @"transformed commit");
	XCTAssertEqualObjects(messageView.string, @"transformed commit");
	XCTAssertTrue(index.lastCommitVerification);
	XCTAssertTrue(controller.isBusy);
	XCTAssertFalse(messageView.editable);
	[self git:@[ @"config", @"--local", @"--unset-all", @"gitx.commitMessageReplacementRules" ] directory:self.repositoryURL];

	messageView.editable = YES;
	messageView.string = NSLocalizedString(@"force commit", nil);
	pushAfterCommitButton.state = NSControlStateValueOn;
	[pushRemotePopUpButton selectItemWithTitle:NSLocalizedString(@"origin", nil)];
	[controller forceCommit:self];
	XCTAssertEqual(index.commitCount, (NSUInteger)2);
	XCTAssertFalse(index.lastCommitVerification);

	self.controller.interceptRemoteRouting = YES;
	[controller commitFinished:[NSNotification notificationWithName:PBGitIndexFinishedCommit
															 object:index
														   userInfo:@{@"description" : @"Committed"}]];
	XCTAssertEqualObjects(messageView.string, @"");
	XCTAssertTrue(messageView.editable);
	XCTAssertEqual(pushAfterCommitButton.state, NSControlStateValueOn);
	XCTAssertTrue([[[PBRepositoryUISettings alloc] initWithRepository:self.repository] pushAfterCommit]);
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)1);
	XCTAssertEqualObjects(self.controller.lastRemote.remoteName, @"origin");
	XCTAssertFalse(self.controller.lastPushRequiresConfirmation);

	messageView.string = NSLocalizedString(@"failed push commit", nil);
	pushAfterCommitButton.state = NSControlStateValueOn;
	[controller forceCommit:self];
	controller.isBusy = YES;
	messageView.editable = NO;
	[controller commitFailed:[NSNotification notificationWithName:PBGitIndexCommitFailed
														   object:index
														 userInfo:@{@"description" : @"rejected"}]];
	XCTAssertFalse(controller.isBusy);
	XCTAssertTrue(messageView.editable);
	XCTAssertEqualObjects(controller.status, @"Commit failed: rejected");
	XCTAssertEqualObjects(PBWindowLastMessage, @"Commit failed");
	[controller commitFinished:[NSNotification notificationWithName:PBGitIndexFinishedCommit object:index]];
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)1);

	messageView.string = NSLocalizedString(@"hook failure commit", nil);
	pushAfterCommitButton.state = NSControlStateValueOn;
	[controller forceCommit:self];
	controller.isBusy = YES;
	messageView.editable = NO;
	[controller commitHookFailed:[NSNotification notificationWithName:PBGitIndexCommitHookFailed
															   object:index
															 userInfo:@{@"description" : @"hook rejected"}]];
	XCTAssertFalse(controller.isBusy);
	XCTAssertTrue(messageView.editable);
	XCTAssertEqualObjects(controller.status, @"Commit hook failed: hook rejected");
	XCTAssertEqual(PBWindowHookCount, (NSUInteger)1);
	[controller commitFinished:[NSNotification notificationWithName:PBGitIndexFinishedCommit object:index]];
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)1);

	controller.isBusy = YES;
	[controller refreshFinished:[NSNotification notificationWithName:PBGitIndexFinishedIndexRefresh object:index]];
	XCTAssertFalse(controller.isBusy);
	XCTAssertEqualObjects(controller.status, @"Index refresh finished");
	[controller commitStatusUpdated:[NSNotification notificationWithName:PBGitIndexCommitStatus
																  object:index
																userInfo:@{@"description" : @"Writing commit"}]];
	XCTAssertEqualObjects(controller.status, @"Writing commit");

	messageView.string = NSLocalizedString(@"keep this message", nil);
	[controller amendCommit:[NSNotification notificationWithName:PBGitIndexAmendMessageAvailable
														  object:index
														userInfo:@{@"message" : @"old message"}]];
	XCTAssertEqualObjects(messageView.string, @"keep this message");
	messageView.string = NSLocalizedString(@"old", nil);
	[controller amendCommit:[NSNotification notificationWithName:PBGitIndexAmendMessageAvailable
														  object:index
														userInfo:@{@"message" : @"restored message"}]];
	XCTAssertEqualObjects(messageView.string, @"restored message");

	[self setCommitFiles:@[] controller:controller];
	[controller indexChanged:[NSNotification notificationWithName:PBGitIndexIndexUpdated object:index]];
	XCTAssertFalse(commitButton.enabled);
	[self setCommitFiles:@[ staged ] controller:controller];
	[controller indexChanged:[NSNotification notificationWithName:PBGitIndexIndexUpdated object:index]];
	XCTAssertTrue(commitButton.enabled);
	[controller indexOperationFailed:[NSNotification notificationWithName:PBGitIndexOperationFailed
																   object:index
																 userInfo:@{@"description" : @"stage failed"}]];
	XCTAssertEqualObjects(PBWindowLastMessage, @"Index operation failed");
	XCTAssertEqualObjects(PBWindowLastInfo, @"stage failed");
	[controller closeView];
}

- (void)testCommitControllerMessageFileAndMutationActions
{
	PBCommitIndexSpy *index = [[PBCommitIndexSpy alloc] initWithRepository:self.repository];
	PBGitCommitController *controller = [self loadedCommitControllerWithIndex:index];
	PBCommitMessageView *messageView = [controller valueForKey:@"commitMessageView"];
	NSArrayController *unstagedController = [controller valueForKey:@"unstagedFilesController"];
	NSArrayController *stagedController = [controller valueForKey:@"stagedFilesController"];
	NSTableView *unstagedTable = [controller valueForKey:@"unstagedTable"];
	NSTableView *stagedTable = [controller valueForKey:@"stagedTable"];
	PBChangedFile *unstaged = [self changedFileWithPath:@"tracked.txt" status:MODIFIED hasStagedChanges:NO hasUnstagedChanges:YES];
	PBChangedFile *staged = [self changedFileWithPath:@"staged.txt" status:MODIFIED hasStagedChanges:YES hasUnstagedChanges:NO];

	messageView.string = NSLocalizedString(@"Subject", nil);
	[controller signOff:self];
	XCTAssertTrue([messageView.string containsString:@"Signed-off-by: GitX Tests <gitx-tests@example.invalid>"]);
	NSString *signedMessage = messageView.string;
	[controller signOff:self];
	XCTAssertEqualObjects(messageView.string, signedMessage);
	PBWindowConfigurationMissingIdentity = YES;
	[controller signOff:self];
	XCTAssertEqualObjects(PBWindowLastMessage, @"User‘s name not set");
	PBWindowConfigurationMissingIdentity = NO;

	messageView.string = NSLocalizedString(@"original", nil);
	index.prepareMessage = nil;
	[controller prepareCommitMessage:self];
	XCTAssertEqualObjects(messageView.string, @"original");
	index.prepareMessage = @"prepared message";
	[controller prepareCommitMessage:self];
	XCTAssertEqualObjects(messageView.string, @"prepared message");
	XCTAssertEqual(index.prepareCount, (NSUInteger)2);
	XCTAssertFalse(controller.isBusy);

	NSUInteger reloadCount = self.repository.reloadRefsCount;
	[controller refresh:nil];
	XCTAssertTrue(controller.isBusy);
	XCTAssertEqualObjects(controller.status, @"Refreshing index…");
	XCTAssertEqual(index.refreshCount, (NSUInteger)1);
	XCTAssertEqual(self.repository.reloadRefsCount, reloadCount + 1);
	XCTAssertFalse(index.isAmend);
	[controller toggleAmendCommit:self];
	XCTAssertTrue(index.isAmend);

	[self setCommitFiles:@[ unstaged, staged ] controller:controller];
	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];
	stagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];
	[controller stageFiles:self];
	[controller unstageFiles:self];
	XCTAssertEqual(index.stageCount, (NSUInteger)1);
	XCTAssertEqual(index.unstageCount, (NSUInteger)1);
	XCTAssertEqualObjects(index.lastFiles, (@[ staged ]));
	[controller fileChangesTableViewDidRequestStagingToggle:(PBFileChangesTableView *)unstagedTable];
	[controller fileChangesTableViewDidRequestStagingToggle:(PBFileChangesTableView *)stagedTable];
	XCTAssertEqual(index.stageCount, (NSUInteger)2);
	XCTAssertEqual(index.unstageCount, (NSUInteger)2);
	XCTestExpectation *reselectionFinished = [self expectationWithDescription:@"commit table reselection finished"];
	dispatch_async(dispatch_get_main_queue(), ^{
		[reselectionFinished fulfill];
	});
	[self waitForExpectations:@[ reselectionFinished ] timeout:1.0];
	XCTAssertEqual(unstagedController.selectionIndex, (NSUInteger)0);
	XCTAssertEqual(stagedController.selectionIndex, (NSUInteger)0);

	self.controller.shouldConfirm = NO;
	[controller discardFiles:self];
	XCTAssertEqual(index.discardCount, (NSUInteger)0);
	self.controller.shouldConfirm = YES;
	[controller discardFiles:self];
	[controller discardFilesForcibly:self];
	XCTAssertEqual(index.discardCount, (NSUInteger)2);
	[self setCommitFiles:@[] controller:controller];
	[controller discardFiles:self];
	[controller discardFilesForcibly:self];
	XCTAssertEqual(index.discardCount, (NSUInteger)2);

	[self setCommitFiles:@[ unstaged ] controller:controller];
	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];
	NSMenuItem *sender = [self commitMenuItemWithAction:@selector(openFiles:) table:unstagedTable];
	XCTAssertEqualObjects([controller selectedFilesForSender:sender], (@[ unstaged ]));
	XCTAssertNil([controller selectedFilesForSender:self]);
	[controller openFiles:sender];
	[controller revealInFinder:sender];
	XCTAssertEqualObjects(self.controller.openedURLs.firstObject.lastPathComponent, @"tracked.txt");
	XCTAssertEqualObjects(self.controller.revealedURLs.firstObject.lastPathComponent, @"tracked.txt");

	self.repository.interceptIgnore = YES;
	self.repository.ignoreSucceeds = YES;
	NSUInteger ignoreRefreshCount = index.refreshCount;
	[controller ignoreFiles:sender];
	XCTAssertTrue([self.repository.operations containsObject:@"ignore:tracked.txt"]);
	XCTAssertEqual(index.refreshCount, ignoreRefreshCount + 1);
	self.repository.ignoreSucceeds = NO;
	[controller ignoreFiles:sender];
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)1);
	XCTAssertEqual(index.refreshCount, ignoreRefreshCount + 2);
	unstagedController.selectionIndexes = [NSIndexSet indexSet];
	[controller ignoreFiles:sender];
	XCTAssertEqual(index.refreshCount, ignoreRefreshCount + 2);

	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];
	NSUInteger trashRefreshCount = index.refreshCount;
	PBWindowTrashSucceeds = NO;
	[controller moveToTrash:sender];
	XCTAssertEqual(PBWindowTrashCount, (NSUInteger)1);
	XCTAssertEqual(index.refreshCount, trashRefreshCount);
	PBWindowTrashSucceeds = YES;
	[controller moveToTrash:sender];
	XCTAssertEqual(PBWindowTrashCount, (NSUInteger)2);
	XCTAssertEqual(index.refreshCount, trashRefreshCount + 1);
	[controller closeView];
}

- (void)testCommitControllerContextMenuPresentationAndEligibility
{
	PBCommitIndexSpy *index = [[PBCommitIndexSpy alloc] initWithRepository:self.repository];
	PBGitCommitController *controller = [self loadedCommitControllerWithIndex:index];
	NSArrayController *unstagedController = [controller valueForKey:@"unstagedFilesController"];
	NSArrayController *stagedController = [controller valueForKey:@"stagedFilesController"];
	NSTableView *unstagedTable = [controller valueForKey:@"unstagedTable"];
	NSTableView *stagedTable = [controller valueForKey:@"stagedTable"];
	PBChangedFile *newFile = [self changedFileWithPath:@"new.txt" status:NEW hasStagedChanges:NO hasUnstagedChanges:YES];
	PBChangedFile *modified = [self changedFileWithPath:@"folder/modified.txt" status:MODIFIED hasStagedChanges:NO hasUnstagedChanges:YES];
	PBChangedFile *staged = [self changedFileWithPath:@"staged.txt" status:MODIFIED hasStagedChanges:YES hasUnstagedChanges:NO];
	[self setCommitFiles:@[ newFile, modified, staged ] controller:controller];
	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)];
	stagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];

	NSMenuItem *stageItem = [self commitMenuItemWithAction:@selector(stageFiles:) table:unstagedTable];
	XCTAssertTrue([controller validateMenuItem:stageItem]);
	XCTAssertEqualObjects(stageItem.title, @"Stage 2 Files");
	XCTAssertFalse(stageItem.hidden);
	NSMenuItem *unstageItem = [self commitMenuItemWithAction:@selector(unstageFiles:) table:stagedTable];
	XCTAssertTrue([controller validateMenuItem:unstageItem]);
	XCTAssertEqualObjects(unstageItem.title, @"Unstage “staged.txt”");

	NSMenuItem *discardItem = [self commitMenuItemWithAction:@selector(discardFiles:) table:unstagedTable];
	XCTAssertTrue([controller validateMenuItem:discardItem]);
	XCTAssertEqualObjects(discardItem.title, @"Discard changes to 2 Files…");
	XCTAssertFalse(discardItem.hidden);
	NSMenuItem *forceDiscardItem = [self commitMenuItemWithAction:@selector(discardFilesForcibly:) table:unstagedTable];
	XCTAssertTrue([controller validateMenuItem:forceDiscardItem]);
	XCTAssertTrue(forceDiscardItem.alternate);
	NSMenuItem *trashItem = [self commitMenuItemWithAction:@selector(moveToTrash:) table:unstagedTable];
	XCTAssertTrue([controller validateMenuItem:trashItem]);
	XCTAssertTrue(trashItem.hidden);

	NSUInteger newFileIndex = [unstagedController.arrangedObjects indexOfObject:newFile];
	XCTAssertNotEqual(newFileIndex, NSNotFound);
	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:newFileIndex];
	XCTAssertTrue([controller validateMenuItem:discardItem]);
	XCTAssertTrue(discardItem.hidden);
	XCTAssertTrue([controller validateMenuItem:trashItem]);
	XCTAssertFalse(trashItem.hidden);
	XCTAssertEqualObjects(trashItem.title, @"Move “new.txt” to Trash");

	NSMenuItem *openItem = [self commitMenuItemWithAction:@selector(openFiles:) table:unstagedTable];
	self.repository.testSubmodule = [PBWindowSubmodule new];
	XCTAssertTrue([controller validateMenuItem:openItem]);
	XCTAssertEqualObjects(openItem.title, @"Open Submodule “new.txt” in GitX");
	self.repository.testSubmodule = nil;
	XCTAssertTrue([controller validateMenuItem:openItem]);
	XCTAssertEqualObjects(openItem.title, @"Open “new.txt”");

	NSMenuItem *ignoreItem = [self commitMenuItemWithAction:@selector(ignoreFiles:) table:unstagedTable];
	XCTAssertTrue([controller validateMenuItem:ignoreItem]);
	XCTAssertFalse(ignoreItem.hidden);
	NSMenuItem *stagedIgnoreItem = [self commitMenuItemWithAction:@selector(ignoreFiles:) table:stagedTable];
	XCTAssertFalse([controller validateMenuItem:stagedIgnoreItem]);
	XCTAssertTrue(stagedIgnoreItem.hidden);
	NSMenuItem *revealItem = [self commitMenuItemWithAction:@selector(revealInFinder:) table:unstagedTable];
	XCTAssertTrue([controller validateMenuItem:revealItem]);
	XCTAssertEqualObjects(revealItem.title, @"Reveal “new.txt” in Finder");
	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)];
	XCTAssertTrue([controller validateMenuItem:revealItem]);
	XCTAssertFalse(revealItem.hidden);
	XCTAssertEqualObjects(revealItem.title, @"Reveal 2 Files in Finder");

	NSMenuItem *amendItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Amend", nil) action:@selector(toggleAmendCommit:) keyEquivalent:@""];
	XCTAssertTrue([controller validateMenuItem:amendItem]);
	XCTAssertEqual(amendItem.state, NSControlStateValueOff);
	index.amend = YES;
	XCTAssertTrue([controller validateMenuItem:amendItem]);
	XCTAssertEqual(amendItem.state, NSControlStateValueOn);
	NSMenuItem *prepareItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Prepare", nil) action:@selector(prepareCommitMessage:) keyEquivalent:@""];
	self.repository.interceptHook = YES;
	self.repository.testHookExists = NO;
	XCTAssertFalse([controller validateMenuItem:prepareItem]);
	self.repository.testHookExists = YES;
	XCTAssertTrue([controller validateMenuItem:prepareItem]);

	unstagedController.selectionIndexes = [NSIndexSet indexSet];
	XCTAssertFalse([controller validateMenuItem:stageItem]);
	XCTAssertTrue(stageItem.hidden);
	XCTAssertEqualObjects(stageItem.title, @"Stage");
	XCTAssertFalse([controller validateMenuItem:openItem]);
	NSMenuItem *otherItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Other", nil) action:@selector(copy:) keyEquivalent:@""];
	otherItem.enabled = YES;
	XCTAssertTrue([controller validateMenuItem:otherItem]);
	[controller menuNeedsUpdate:unstagedTable.menu];
	[controller closeView];
}

- (void)testCommitControllerResponderTableAndDragInteractions
{
	PBCommitIndexSpy *index = [[PBCommitIndexSpy alloc] initWithRepository:self.repository];
	PBGitCommitController *controller = [self loadedCommitControllerWithIndex:index];
	PBCommitMessageView *messageView = [controller valueForKey:@"commitMessageView"];
	NSArrayController *unstagedController = [controller valueForKey:@"unstagedFilesController"];
	NSArrayController *stagedController = [controller valueForKey:@"stagedFilesController"];
	NSTableView *unstagedTable = [controller valueForKey:@"unstagedTable"];
	NSTableView *stagedTable = [controller valueForKey:@"stagedTable"];
	PBChangedFile *unstaged = [self changedFileWithPath:@"tracked.txt" status:MODIFIED hasStagedChanges:NO hasUnstagedChanges:YES];
	PBChangedFile *staged = [self changedFileWithPath:@"staged.txt" status:MODIFIED hasStagedChanges:YES hasUnstagedChanges:NO];
	[self setCommitFiles:@[ unstaged, staged ] controller:controller];
	[unstagedTable reloadData];
	[stagedTable reloadData];

	XCTAssertTrue([controller textView:messageView doCommandBySelector:@selector(insertTab:)]);
	XCTAssertEqual(self.controller.window.firstResponder, stagedTable);
	XCTAssertEqual(stagedTable.selectedRow, (NSInteger)0);
	XCTAssertTrue([controller textView:messageView doCommandBySelector:@selector(insertBacktab:)]);
	XCTAssertEqual(self.controller.window.firstResponder, unstagedTable);
	XCTAssertFalse([controller textView:messageView doCommandBySelector:@selector(insertNewline:)]);

	unstagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];
	stagedController.selectionIndexes = [NSIndexSet indexSetWithIndex:0];
	[controller didDoubleClickOnTable:unstagedTable];
	[controller didDoubleClickOnTable:stagedTable];
	XCTAssertEqual(index.stageCount, (NSUInteger)1);
	XCTAssertEqual(index.unstageCount, (NSUInteger)1);
	NSTableColumn *column = unstagedTable.tableColumns.firstObject;
	[controller tableView:unstagedTable willDisplayCell:column.dataCell forTableColumn:column row:0];

	NSPasteboard *unstagedPasteboard = [NSPasteboard pasteboardWithUniqueName];
	XCTAssertTrue([controller tableView:unstagedTable
				   writeRowsWithIndexes:[NSIndexSet indexSetWithIndex:0]
						   toPasteboard:unstagedPasteboard]);
	XCTAssertEqualObjects([unstagedPasteboard propertyListForType:@"NSFilenamesPboardType"],
						  (@[ [self.repository.workingDirectoryURL URLByAppendingPathComponent:@"tracked.txt"].path ]));
	PBCommitDraggingInfo *dragInfo = [PBCommitDraggingInfo new];
	dragInfo.testPasteboard = unstagedPasteboard;
	dragInfo.testSource = unstagedTable;
	XCTAssertEqual([controller tableView:unstagedTable
								validateDrop:(id<NSDraggingInfo>)dragInfo
								 proposedRow:0
					   proposedDropOperation:NSTableViewDropAbove],
				   NSDragOperationNone);
	dragInfo.testSource = stagedTable;
	XCTAssertEqual([controller tableView:unstagedTable
								validateDrop:(id<NSDraggingInfo>)dragInfo
								 proposedRow:0
					   proposedDropOperation:NSTableViewDropAbove],
				   NSDragOperationCopy);
	XCTAssertTrue([controller tableView:stagedTable
							 acceptDrop:(id<NSDraggingInfo>)dragInfo
									row:0
						  dropOperation:NSTableViewDropOn]);
	XCTAssertEqual(index.stageCount, (NSUInteger)2);

	NSPasteboard *stagedPasteboard = [NSPasteboard pasteboardWithUniqueName];
	XCTAssertTrue([controller tableView:stagedTable
				   writeRowsWithIndexes:[NSIndexSet indexSetWithIndex:0]
						   toPasteboard:stagedPasteboard]);
	dragInfo.testPasteboard = stagedPasteboard;
	XCTAssertTrue([controller tableView:unstagedTable
							 acceptDrop:(id<NSDraggingInfo>)dragInfo
									row:0
						  dropOperation:NSTableViewDropOn]);
	XCTAssertEqual(index.unstageCount, (NSUInteger)2);

	NSPasteboard *invalidPasteboard = [NSPasteboard pasteboardWithUniqueName];
	[invalidPasteboard declareTypes:@[ @"GitFileChangedType" ] owner:nil];
	[invalidPasteboard setData:[@"invalid" dataUsingEncoding:NSUTF8StringEncoding] forType:@"GitFileChangedType"];
	dragInfo.testPasteboard = invalidPasteboard;
	XCTAssertFalse([controller tableView:stagedTable
							  acceptDrop:(id<NSDraggingInfo>)dragInfo
									 row:0
						   dropOperation:NSTableViewDropOn]);
	NSPasteboard *missingRowsPasteboard = [NSPasteboard pasteboardWithUniqueName];
	dragInfo.testPasteboard = missingRowsPasteboard;
	XCTAssertFalse([controller tableView:stagedTable
							  acceptDrop:(id<NSDraggingInfo>)dragInfo
									 row:0
						   dropOperation:NSTableViewDropOn]);

	[self setCommitFiles:@[] controller:controller];
	[unstagedTable reloadData];
	[controller focusTable:unstagedTable];
	XCTAssertEqual(unstagedTable.numberOfRows, (NSInteger)0);
	[controller closeView];
}

- (void)testRealNibLifecycleContentSwitchingStatusAndValidation
{
	PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] init];
	[document setValue:self.repository forKey:@"_repository"];
	PBGitWindowController *controller = [[PBGitWindowController alloc] init];
	controller.document = document;
	BOOL previousShowStageView = PBGitDefaults.showStageView;
	[PBGitDefaults setShowStageView:YES];
	NSWindow *window = controller.window;

	XCTAssertNotNil(window);
	PBGitSidebarController *sidebar = [controller valueForKey:@"_sidebarController"];
	PBGitHistoryController *history = [controller valueForKey:@"_historyViewController"];
	PBGitCommitController *commit = [controller valueForKey:@"_commitViewController"];
	XCTAssertNotNil(sidebar);
	XCTAssertNotNil(history);
	XCTAssertNotNil(commit);
	[sidebar reloadSidebarAfterReferencesChange];
	[PBGitDefaults setShowStageView:previousShowStageView];
	XCTAssertEqualObjects(window.representedURL, self.repository.workingDirectoryURL);
	XCTAssertEqualObjects([controller valueForKeyPath:@"jumpToCheckedOutBranchButton.accessibilityIdentifier"], @"JumpToCheckedOutBranchButton");

	NSMenuItem *commitItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Commit", nil) action:@selector(showCommitView:) keyEquivalent:@""];
	NSMenuItem *historyItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"History", nil) action:@selector(showHistoryView:) keyEquivalent:@""];
	XCTAssertTrue([controller validateMenuItem:commitItem]);
	XCTAssertTrue([controller validateMenuItem:historyItem]);
	XCTAssertTrue([controller validateMenuItem:[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Other", nil) action:@selector(copy:) keyEquivalent:@""]]);

	[controller changeContentController:history];
	history.status = @"History ready";
	history.isBusy = YES;
	[controller updateStatus];
	XCTAssertEqualObjects([[controller valueForKey:@"statusField"] stringValue], @"History ready");
	XCTAssertFalse([[controller valueForKey:@"progressIndicator"] isHidden]);
	[controller showCommitView:self];
	XCTAssertTrue(controller.isShowingCommitView);
	[controller showHistoryView:self];
	XCTAssertFalse(controller.isShowingCommitView);
	[controller changeContentController:commit];
	[controller changeContentController:commit];
	PBWindowSendObject(controller, @selector(changeContentController:), nil);

	[controller setHistorySearch:@"initial" mode:PBHistorySearchModeBasic];
	[controller synchronizeWindowTitleWithDocumentName];
	[controller showCommitView:self];
	[controller showHistoryView:self];
	[controller removeAllContentSubViews];
	[controller windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:window]];
	XCTAssertNil(controller.sidebarViewController);
	XCTAssertNil(controller.historyViewController);
	XCTAssertNil(controller.commitViewController);
	[window orderOut:nil];
	[window close];
}

- (void)testContentStatusRefreshAndViewRoutingWithProgrammaticCollaborators
{
	NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	NSTextField *status = [NSTextField labelWithString:@""];
	NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
	[self.controller setValue:container forKey:@"contentSplitView"];
	[self.controller setValue:status forKey:@"statusField"];
	[self.controller setValue:progress forKey:@"progressIndicator"];
	PBWindowContentSpy *content = [PBWindowContentSpy new];
	PBWindowContentSpy *secondContent = [PBWindowContentSpy new];
	content.status = @"Busy";
	content.isBusy = YES;
	[self.controller changeContentController:content];
	XCTAssertEqual(content.updateCount, (NSUInteger)1);
	[self.controller changeContentController:secondContent];
	[self.controller changeContentController:content];
	XCTAssertEqual(content.updateCount, (NSUInteger)1);
	XCTAssertEqual(secondContent.updateCount, (NSUInteger)1);
	XCTAssertEqual(content.view.superview, container);
	XCTAssertEqual(secondContent.view.superview, container);
	XCTAssertFalse(content.view.hidden);
	XCTAssertTrue(secondContent.view.hidden);
	XCTAssertEqualObjects(status.stringValue, @"Busy");
	XCTAssertFalse(progress.hidden);
	XCTAssertFalse(self.controller.isShowingCommitView);
	[self.controller setValue:content forKey:@"_commitViewController"];
	XCTAssertTrue(self.controller.isShowingCommitView);

	self.controller.interceptRemoteRouting = YES;
	[self.controller toolbarFetch:self];
	[self.controller toolbarPull:self];
	[self.controller toolbarPush:self];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.pullRouteCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)1);
	[self.controller viewRemote:self];

	content.status = nil;
	content.isBusy = YES;
	[self.controller updateStatus];
	XCTAssertEqualObjects(status.stringValue, @"");
	XCTAssertTrue(progress.hidden);
	[self.controller setValue:content forKey:@"contentController"];
	[self.controller refresh:self];
	XCTAssertEqual(self.controller.refreshCount, (NSUInteger)1);
	PBGitWindowController *baseController = [[PBGitWindowController alloc] initWithWindow:self.controller.window];
	[baseController setValue:content forKey:@"contentController"];
	[baseController refresh:self];
	XCTAssertEqual(content.refreshCount, (NSUInteger)1);

	PBWindowSidebarSpy *sidebar = [[PBWindowSidebarSpy alloc] initWithRepository:self.repository superController:self.controller];
	[self.controller setValue:sidebar forKey:@"_sidebarController"];
	[self.controller showCommitView:self];
	[self.controller showHistoryView:self];
	XCTAssertEqual(sidebar.stageSelectionCount, (NSUInteger)1);
	XCTAssertEqual(sidebar.branchSelectionCount, (NSUInteger)1);
	[self.controller jumpToCheckedOutBranch:self];
	XCTAssertEqual(sidebar.branchSelectionCount, (NSUInteger)2);
}

- (void)testContentObservationDoesNotRetainWindowController
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
												   styleMask:NSWindowStyleMaskTitled
													 backing:NSBackingStoreBuffered
													   defer:NO];
	PBWindowContentSpy *content = [PBWindowContentSpy new];
	__weak PBGitWindowController *weakController = nil;
	@autoreleasepool {
		PBGitWindowController *controller = [[PBGitWindowController alloc] initWithWindow:window];
		NSView *container = [[NSView alloc] initWithFrame:window.contentView.bounds];
		[controller setValue:container forKey:@"contentSplitView"];
		[controller changeContentController:content];
		weakController = controller;
		controller = nil;
	}

	XCTAssertNil(weakController);
	[window orderOut:nil];
	[window close];
}

- (void)testActionContextResolutionFromMenusSidebarAndHistory
{
	XCTAssertEqual([self.controller refishForSender:[self menuItemWithObject:self.branchRef] refishTypes:@[ kGitXBranchType ]], self.branchRef);
	XCTAssertNil([self.controller refishForSender:[self menuItemWithObject:self.branchRef] refishTypes:@[ kGitXTagType ]]);
	id<PBGitRefish> namedRemote = [self.controller refishForSender:[self menuItemWithObject:@"origin"] refishTypes:@[ kGitXRemoteType ]];
	XCTAssertEqualObjects(namedRemote.refishType, kGitXRemoteType);
	XCTAssertNil([self.controller refishForSender:[self menuItemWithObject:@"missing"] refishTypes:@[ kGitXRemoteType ]]);
	XCTAssertNil([self.controller refishForSender:self refishTypes:@[ kGitXBranchType ]]);

	PBWindowHistorySpy *history = [[PBWindowHistorySpy alloc] initWithRepository:self.repository superController:self.controller];
	history.selectedCommits = @[ self.headCommit ];
	history.testCommitList = (PBCommitList *)[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
	[self.controller setValue:history forKey:@"_historyViewController"];
	XCTAssertEqual([self.controller refishForSender:self refishTypes:@[ kGitXCommitType ]], self.headCommit);

	PBWindowOutlineView *outline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
	PBWindowSidebarSpy *sidebar = [[PBWindowSidebarSpy alloc] initWithRepository:self.repository superController:self.controller];
	sidebar.testSourceView = outline;
	sidebar.testRemotes = [PBSourceViewItem groupItemWithTitle:@"Remotes"];
	PBSourceViewItem *branchItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:self.branchRef]];
	outline.testItem = branchItem;
	[self.controller setValue:sidebar forKey:@"_sidebarController"];
	[self.controller setValue:sidebar forKey:@"_sidebarViewController"];
	self.controller.window.contentView = outline;
	((PBWindowTestWindow *)self.controller.window).testFirstResponder = outline;
	XCTAssertEqualObjects([self.controller selectedRef].ref, self.branchRef.ref);
	NSMenuItem *fetch = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Fetch", nil) action:@selector(fetchRemote:) keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:fetch]);
	XCTAssertTrue([fetch.title containsString:@"origin"]);

	PBSourceViewItem *remoteItem = [PBSourceViewItem itemWithTitle:@"origin"];
	remoteItem.revSpecifier = [[PBGitRevSpecifier alloc] initWithRef:self.remoteBranchRef];
	remoteItem.parent = sidebar.testRemotes;
	outline.testItem = remoteItem;
	XCTAssertTrue([self.controller selectedRef].isRemote);

	self.headCommit.refs = [NSMutableArray arrayWithObject:self.branchRef];
	self.controller.window.contentView = (NSView *)history.testCommitList;
	((PBWindowTestWindow *)self.controller.window).testFirstResponder = (NSResponder *)history.testCommitList;
	XCTAssertEqual([self.controller selectedRef], self.branchRef);
	[self.headCommit.refs addObject:[PBGitRef refFromString:@"refs/heads/feature"]];
	XCTAssertNil([self.controller selectedRef]);
	((PBWindowTestWindow *)self.controller.window).testFirstResponder = self.controller.window.contentView;
	XCTAssertNil([self.controller selectedRef]);
}

- (void)testRemoteProgressWorkflowsSuccessFailureAndRouting
{
	[self.controller performFetchForRef:nil];
	XCTAssertEqualObjects(PBWindowLastProgressDescription, @"Fetching all remotes");
	XCTAssertEqual(PBWindowManualFetchCount, (NSUInteger)1);
	[self.controller performFetchForRef:self.remoteBranchRef];
	XCTAssertTrue([PBWindowLastProgressDescription containsString:@"origin"]);
	[self.controller performFetchForRef:self.branchRef];
	XCTAssertTrue([PBWindowLastProgressDescription containsString:@"main"]);

	[self.controller performPullForBranch:self.branchRef remote:nil rebase:NO];
	PBWindowPerformPull(self.controller, nil, self.remoteRef, YES);
	[self.controller performPullForBranch:self.branchRef remote:self.remoteRef rebase:NO];
	XCTAssertTrue([PBWindowLastProgressDescription containsString:@"origin"]);
	PBWindowPerformPull(self.controller, nil, self.branchRef, NO);
	XCTAssertEqual([self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'pull'"]].count, (NSUInteger)4);
	XCTAssertEqual([self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'pullRebase'"]].count, (NSUInteger)1);

	[self.controller performPushForBranch:self.branchRef toRemote:self.remoteRef requiresConfirmation:NO];
	[self.controller performPushForBranch:self.branchRef toRemote:nil requiresConfirmation:NO];
	[self.controller performPushForBranch:nil toRemote:self.remoteRef requiresConfirmation:NO];
	XCTAssertEqualObjects(PBWindowLastProgressTitle, @"Pushing remote…");
	NSUInteger pushCount = [self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'push'"]].count;
	[self.controller performPushForBranch:nil toRemote:nil];
	[self.controller performPushForBranch:[PBGitRef refFromString:kGitXStashRefPrefix] toRemote:nil];
	[self.controller performPushForBranch:self.branchRef toRemote:self.branchRef];
	XCTAssertEqual([self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'push'"]].count, pushCount);

	self.controller.shouldConfirm = NO;
	[self.controller performPushForBranch:self.branchRef toRemote:self.remoteRef];
	self.controller.shouldConfirm = YES;
	[self.controller performPushForBranch:self.branchRef toRemote:self.remoteRef];
	XCTAssertGreaterThan(self.controller.confirmations.count, (NSUInteger)1);

	self.repository.failingOperation = @"fetch";
	[self.controller performFetchForRef:nil];
	self.repository.failingOperation = @"pull";
	[self.controller performPullForBranch:self.branchRef remote:nil rebase:NO];
	self.repository.failingOperation = @"push";
	[self.controller performPushForBranch:self.branchRef toRemote:nil requiresConfirmation:NO];
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)3);
	self.repository.failingOperation = nil;

	self.controller.interceptRemoteRouting = YES;
	[self.controller fetchRemote:[self menuItemWithObject:self.branchRef]];
	[self.controller fetchRemote:[self menuItemWithObject:self.tagRef]];
	[self.controller fetchAllRemotes:self];
	[self.controller pullRemote:[self menuItemWithObject:self.branchRef]];
	[self.controller pullRebaseRemote:[self menuItemWithObject:self.branchRef]];
	[self.controller pullDefaultRemote:[self menuItemWithObject:self.branchRef]];
	[self.controller pullRebaseDefaultRemote:[self menuItemWithObject:self.branchRef]];
	[self.controller pushUpdatesToRemote:[self menuItemWithObject:self.remoteRef]];
	[self.controller pushDefaultRemoteForRef:[self menuItemWithObject:self.branchRef]];
	NSMenuItem *parent = [self menuItemWithObject:self.branchRef];
	NSMenu *rootMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Reference", nil)];
	[rootMenu addItem:parent];
	NSMenu *submenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Remotes", nil)];
	parent.submenu = submenu;
	NSMenuItem *remoteItem = [self menuItemWithObject:@"origin"];
	[submenu addItem:remoteItem];
	[self.controller pushToRemote:remoteItem];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)2);
	XCTAssertEqual(self.controller.pullRouteCount, (NSUInteger)4);
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)3);
}

- (void)testRemoteProgressExecutionRunsSafelyOffTheMainQueue
{
	PBWindowRunProgressInBackground = YES;
	PBWindowProgressExpectation = [self expectationWithDescription:@"background push completed"];

	[self.controller performPushForBranch:self.branchRef toRemote:self.remoteRef requiresConfirmation:NO];
	[self waitForExpectations:@[ PBWindowProgressExpectation ] timeout:5.0];

	XCTAssertEqual([self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'push'"]].count, (NSUInteger)1);
}

- (void)testRemoteAddAndMenuValidationMatrices
{
	self.controller.interceptRemoteRouting = YES;
	PBWindowAddRemoteResponse = NSModalResponseCancel;
	PBWindowSendObject(self.controller, @selector(showAddRemoteSheet:), self);
	PBWindowAddRemoteResponse = NSModalResponseOK;
	[self.controller addRemote:self];
	XCTAssertTrue([self.repository.operations containsObject:@"addRemote"]);
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)1);

	self.repository.failingOperation = @"addRemote";
	[self.controller addRemote:self];
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)1);
	self.repository.failingOperation = nil;

	PBWindowHistorySpy *history = [[PBWindowHistorySpy alloc] initWithRepository:self.repository superController:self.controller];
	history.selectedCommits = @[ self.headCommit ];
	[self.controller setValue:history forKey:@"_historyViewController"];
	NSMenuItem *fetch = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Fetch", nil) action:@selector(fetchRemote:) keyEquivalent:@""];
	NSMenuItem *pull = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Pull", nil) action:@selector(pullRemote:) keyEquivalent:@""];
	NSMenuItem *rebase = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Pull", nil) action:@selector(pullRebaseRemote:) keyEquivalent:@""];
	XCTAssertFalse([self.controller validateMenuItem:fetch]);
	XCTAssertFalse([self.controller validateMenuItem:pull]);
	XCTAssertFalse([self.controller validateMenuItem:rebase]);
	NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Settings", nil) action:@selector(showRepositorySettings:) keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:settings]);
}

- (void)testReferenceMutationActionsSuccessFailureInvalidAndCreation
{
	NSArray<NSMenuItem *> *validItems = @[
		[self menuItemWithObject:self.branchRef],
		[self menuItemWithObject:self.remoteBranchRef],
		[self menuItemWithObject:self.headCommit],
		[self menuItemWithObject:self.tagRef],
	];
	for (NSMenuItem *item in validItems) {
		[self.controller checkout:item];
		[self.controller merge:item];
	}
	[self.controller rebase:[self menuItemWithObject:self.headCommit]];
	[self.controller rebaseHeadBranch:[self menuItemWithObject:self.branchRef]];
	[self.controller cherryPick:[self menuItemWithObject:self.headCommit]];
	[self.controller resetSoft:[self menuItemWithObject:self.branchRef]];
	[self.controller deleteRef:[self menuItemWithObject:self.branchRef]];
	XCTAssertTrue([self.repository.operations containsObject:@"delete"]);

	NSUInteger count = self.repository.operations.count;
	[self.controller checkout:self];
	[self.controller merge:self];
	[self.controller rebase:self];
	[self.controller rebaseHeadBranch:self];
	[self.controller cherryPick:self];
	[self.controller resetSoft:self];
	[self.controller deleteRef:[self menuItemWithObject:[NSObject new]]];
	XCTAssertEqual(self.repository.operations.count, count);

	NSArray<NSString *> *failures = @[ @"checkout", @"merge", @"rebase", @"cherryPick", @"reset", @"delete" ];
	for (NSString *operation in failures) {
		self.repository.failingOperation = operation;
		if ([operation isEqualToString:@"checkout"])
			[self.controller checkout:[self menuItemWithObject:self.branchRef]];
		else if ([operation isEqualToString:@"merge"])
			[self.controller merge:[self menuItemWithObject:self.branchRef]];
		else if ([operation isEqualToString:@"rebase"])
			[self.controller rebase:[self menuItemWithObject:self.headCommit]];
		else if ([operation isEqualToString:@"cherryPick"])
			[self.controller cherryPick:[self menuItemWithObject:self.headCommit]];
		else if ([operation isEqualToString:@"reset"])
			[self.controller resetSoft:[self menuItemWithObject:self.branchRef]];
		else
			[self.controller deleteRef:[self menuItemWithObject:self.branchRef]];
	}
	XCTAssertEqual(self.controller.shownErrors.count, failures.count);
	self.repository.failingOperation = nil;

	PBWindowCreateBranchResponse = NSModalResponseCancel;
	[self.controller createBranch:[self menuItemWithObject:self.branchRef]];
	PBWindowCreateBranchResponse = NSModalResponseOK;
	PBWindowCreateBranchTestSheet.shouldCheckoutBranch = NO;
	[self.controller createBranch:[self menuItemWithObject:self.branchRef]];
	PBWindowCreateBranchTestSheet.shouldCheckoutBranch = YES;
	[self.controller createBranch:self];
	XCTAssertTrue([self.repository.operations containsObject:@"createBranch"]);
	self.repository.failingOperation = @"createBranch";
	[self.controller createBranch:self];

	self.repository.failingOperation = nil;
	PBWindowCreateTagResponse = NSModalResponseCancel;
	[self.controller createTag:[self menuItemWithObject:self.tagRef]];
	PBWindowCreateTagResponse = NSModalResponseOK;
	[self.controller createTag:[self menuItemWithObject:self.tagRef]];
	self.repository.failingOperation = @"createTag";
	[self.controller createTag:self];
	XCTAssertGreaterThanOrEqual(self.controller.shownErrors.count, failures.count + 2);
	self.repository.failingOperation = nil;

	[self.controller diffWithHEAD:[self menuItemWithObject:self.headCommit]];
	[self.controller diffWithHEAD:[self menuItemWithObject:self.branchRef]];
	[self.controller diffWithHEAD:self];
	XCTAssertEqual(PBWindowDiffCount, (NSUInteger)2);
	[self.controller showTagInfoSheet:[self menuItemWithObject:self.tagRef]];
	XCTAssertEqual(PBWindowMessageCount, (NSUInteger)1);
	XCTAssertTrue([PBWindowLastMessage containsString:@"v1"]);
	[self.controller showTagInfoSheet:self];
}

- (void)testStashActionsSuccessFailureFallbackConfirmationAndDiff
{
	NSMenuItem *stashItem = [self menuItemWithObject:self.stash.ref];
	[self.controller stashSave:self];
	[self.controller stashSaveWithKeepIndex:self];
	[self.controller stashPop:stashItem];
	[self.controller stashPop:self];
	[self.controller stashApply:stashItem];
	[self.controller stashDrop:stashItem];
	[self.controller stashDrop:self];
	[self.controller stashViewDiff:stashItem];
	XCTAssertEqual(PBWindowStashDiffCount, (NSUInteger)1);

	NSArray<NSString *> *failures = @[ @"stashSave", @"stashSaveKeep", @"stashPop", @"stashApply", @"stashDrop" ];
	for (NSString *operation in failures) {
		self.repository.failingOperation = operation;
		if ([operation isEqualToString:@"stashSave"])
			[self.controller stashSave:self];
		else if ([operation isEqualToString:@"stashSaveKeep"])
			[self.controller stashSaveWithKeepIndex:self];
		else if ([operation isEqualToString:@"stashPop"])
			[self.controller stashPop:stashItem];
		else if ([operation isEqualToString:@"stashApply"])
			[self.controller stashApply:stashItem];
		else
			[self.controller stashDrop:stashItem];
	}
	XCTAssertEqual(self.controller.shownErrors.count, failures.count);
	self.repository.failingOperation = nil;
	self.controller.shouldConfirm = NO;
	NSUInteger dropCount = [self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'stashDrop'"]].count;
	[self.controller stashDrop:stashItem];
	XCTAssertEqual([self.repository.operations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'stashDrop'"]].count, dropCount);
}

- (void)testWorkspacePathNormalizationOpenRevealAndTerminalRouting
{
	id previousTerminal = [NSUserDefaults.standardUserDefaults objectForKey:@"PBTerminalBundleIdentifier"];
	[NSUserDefaults.standardUserDefaults setObject:@"com.apple.Terminal" forKey:@"PBTerminalBundleIdentifier"];
	PBChangedFile *changed = [[PBChangedFile alloc] initWithPath:@"tracked.txt"];
	NSMenuItem *item = [self menuItemWithObject:@[ @" stash.txt ", changed, @42 ]];
	NSArray<NSURL *> *urls = [self.controller selectedURLsFromSender:item];
	XCTAssertEqual(urls.count, (NSUInteger)2);
	XCTAssertNil([self.controller selectedURLsFromSender:[self menuItemWithObject:@[]]]);
	XCTAssertNil([self.controller selectedURLsFromSender:[self menuItemWithObject:@"tracked.txt"]]);
	[self.controller openFiles:item];
	XCTAssertEqual(self.controller.openedURLs.count, (NSUInteger)2);
	[self.controller revealInFinder:self];
	XCTAssertEqualObjects(self.controller.revealedURLs, @[ self.repository.workingDirectoryURL ]);
	[self.controller openInTerminal:self];
	XCTAssertEqual(PBWindowTerminalCount, (NSUInteger)1);
	XCTAssertEqualObjects(PBWindowLastTerminalCommand, @"git status");
	XCTAssertEqualObjects(PBWindowLastTerminalDirectory, self.repository.workingDirectoryURL);

	PBGitWindowController *directController = [[PBGitWindowController alloc] initWithWindow:self.controller.window];
	PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] init];
	[document setValue:self.repository forKey:@"_repository"];
	directController.document = document;
	[directController openURLs:@[]];
	[directController revealURLsInFinder:@[]];
	[directController openURLs:@[ [self.repository.workingDirectoryURL URLByAppendingPathComponent:@"tracked.txt"] ]];
	[directController revealURLsInFinder:@[ self.repository.workingDirectoryURL ]];
	XCTAssertEqual(PBWindowWorkspaceOpenCount, (NSUInteger)1);
	XCTAssertEqual(PBWindowWorkspaceRevealCount, (NSUInteger)1);

	PBWindowSubmodule *submodule = [PBWindowSubmodule new];
	submodule.path = @"Submodule";
	submodule.parentRepository = self.repository.gtRepo;
	self.repository.testSubmodule = submodule;
	[directController openURLs:@[ [self.repository.workingDirectoryURL URLByAppendingPathComponent:@"Submodule"] ]];
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)1);
	if (previousTerminal)
		[NSUserDefaults.standardUserDefaults setObject:previousTerminal forKey:@"PBTerminalBundleIdentifier"];
	else
		[NSUserDefaults.standardUserDefaults removeObjectForKey:@"PBTerminalBundleIdentifier"];
}

- (void)testPreferencesWindowCharacterizesExistingToolbarAndSizing
{
	PBPrefsWindowController *preferences = [[PBPrefsWindowController alloc] initWithWindowNibName:@"Preferences"];
	[preferences showWindow:nil];
	NSArray<NSToolbarItemIdentifier> *identifiers = [preferences toolbarAllowedItemIdentifiers:preferences.window.toolbar];

	XCTAssertEqual(identifiers.count, (NSUInteger)7);
	XCTAssertEqualObjects(identifiers, (@[ @"General", @"Windows", @"Diff & Text", @"Terminal", @"Integration", @"History & Fetch", @"Updates" ]));
	XCTAssertFalse((preferences.window.styleMask & NSWindowStyleMaskResizable) != 0);
	XCTAssertEqual(preferences.window.toolbar.displayMode, NSToolbarDisplayModeIconAndLabel);
	XCTAssertFalse(preferences.window.toolbar.allowsUserCustomization);
	XCTAssertGreaterThanOrEqual(preferences.window.frame.size.width, 756.0);

	[preferences close];
}

- (void)testRepositoryToolbarHasIndependentHistoryAndCommitConfigurations
{
	PBRepositoryToolbarController *toolbarController = [[PBRepositoryToolbarController alloc] initWithWindowController:self.controller];
	[toolbarController install];
	NSToolbar *historyToolbar = self.controller.window.toolbar;

	XCTAssertEqualObjects(historyToolbar.identifier, @"GitX.Repository.HistoryToolbar");
	XCTAssertTrue(historyToolbar.allowsUserCustomization);
	XCTAssertTrue(historyToolbar.autosavesConfiguration);
	XCTAssertEqual(historyToolbar.displayMode, NSToolbarDisplayModeIconAndLabel);
	NSArray<NSToolbarItemIdentifier> *historyDefaults = [toolbarController toolbarDefaultItemIdentifiers:historyToolbar];
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Commit"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.ViewRemote"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.RefreshStatus"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Actions"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Reveal"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Terminal"]);

	[toolbarController updateWithStatus:@"Loading commits" busy:YES baseWindowTitle:@"Repository"];
	XCTAssertEqualObjects(self.controller.window.title, @"Repository — Loading commits");

	[toolbarController setHistoryMode:NO];
	NSToolbar *commitToolbar = self.controller.window.toolbar;
	XCTAssertEqualObjects(commitToolbar.identifier, @"GitX.Repository.CommitToolbar");
	NSArray<NSToolbarItemIdentifier> *commitDefaults = [toolbarController toolbarDefaultItemIdentifiers:commitToolbar];
	XCTAssertTrue([commitDefaults containsObject:@"GitX.Toolbar.History"]);
	XCTAssertTrue([commitDefaults containsObject:@"GitX.Toolbar.Terminal"]);
	XCTAssertFalse([commitDefaults containsObject:@"GitX.Toolbar.Push"]);

	[toolbarController setHistoryMode:YES];
	XCTAssertEqual(self.controller.window.toolbar, historyToolbar);
}

- (void)testRepositoryCommitMessageReplacementRulesAreOrderedAndMultiline
{
	NSString *rules = @"(?m)^WIP:[ \\t]* => \n(?m)^Ticket: ([0-9]+)$ => Refs #$1";
	[self git:@[ @"config", @"--local", @"gitx.commitMessageReplacementRules", rules ] directory:self.repositoryURL];
	PBCommitMessageTransformer *transformer = [[PBCommitMessageTransformer alloc] initWithRepository:self.repository];
	NSError *error = nil;
	NSString *result = [transformer transformMessage:@"WIP: Add toolbar\n\nTicket: 42" error:&error];

	XCTAssertNil(error);
	XCTAssertEqualObjects(result, @"Add toolbar\n\nRefs #42");

	NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 120)];
	textView.string = @"WIP: Add toolbar\n\nTicket: 42";
	NSString *edited = [PBCommitMessageEditCoordinator transformMessage:textView.string
															 inTextView:textView
															 repository:self.repository
																  error:&error];
	XCTAssertEqualObjects(edited, result);
	XCTAssertEqualObjects(textView.string, result);
}

- (void)testRemoteWebURLsSupportCommonGitHostsAndServerOutput
{
	PBRepositoryRemoteURLCoordinator *coordinator = PBRepositoryRemoteURLCoordinator.shared;
	XCTAssertEqualObjects([coordinator firstHTTPURLInOutput:@"remote: Open https://github.com/acme/repo/pull/7 to review."].absoluteString,
						  @"https://github.com/acme/repo/pull/7");
	XCTAssertEqualObjects([coordinator webURLForRemoteURL:@"git@github.com:acme/repo.git" branch:@"feature/settings" sha:@"abc"].absoluteString,
						  @"https://github.com/acme/repo/tree/feature/settings");
	XCTAssertEqualObjects([coordinator webURLForRemoteURL:@"ssh://git@gitlab.example/acme/repo.git" branch:@"main" sha:@"abc"].absoluteString,
						  @"https://gitlab.example/acme/repo/-/tree/main");
	XCTAssertEqualObjects([coordinator webURLForRemoteURL:@"https://bitbucket.org/acme/repo.git" branch:@"" sha:@"abc123"].absoluteString,
						  @"https://bitbucket.org/acme/repo/src/abc123");
}

- (void)testFileHistoryEntriesParseStructuredGitLogOutput
{
	GLFileView *fileView = [GLFileView new];
	NSArray<NSDictionary *> *entries = [fileView historyEntriesForTree:[PBWindowHistoryTreeLogStub new]];

	XCTAssertEqual(entries.count, (NSUInteger)1);
	XCTAssertEqualObjects(entries.firstObject[@"subject"], @"Toolbar history");
	XCTAssertEqualObjects(entries.firstObject[@"author"], @"Ada");
	XCTAssertEqualObjects(entries.firstObject[@"date"], @"now");
	XCTAssertEqualObjects(entries.firstObject[@"sha"], @"abc123456789");
}

- (void)testWelcomeWindowSearchAndCloseActions
{
	PBWelcomeWindowController *welcome = PBWelcomeWindowController.shared;
	id originalRecents = [NSUserDefaults.standardUserDefaults objectForKey:@"PBRecentRepositories"];
	[[PBRecentRepositoryStore shared] record:self.repositoryURL];
	[welcome showWindow:nil];
	[welcome searchChanged:nil];
	NSArray<NSView *> *descendants = welcome.window.contentView.subviews;
	NSTableView *recentsTable = nil;
	while (descendants.count > 0 && !recentsTable) {
		NSView *view = descendants.firstObject;
		descendants = [descendants subarrayWithRange:NSMakeRange(1, descendants.count - 1)];
		if ([view isKindOfClass:NSTableView.class] &&
			[view.accessibilityIdentifier isEqualToString:@"WelcomeRecents"]) {
			recentsTable = (NSTableView *)view;
		} else {
			descendants = [descendants arrayByAddingObjectsFromArray:view.subviews];
		}
	}

	XCTAssertNotNil(recentsTable);
	XCTAssertEqual(recentsTable.target, welcome);
	XCTAssertEqual(recentsTable.doubleAction, NSSelectorFromString(@"openSelected:"));
	XCTAssertGreaterThan(recentsTable.numberOfRows, (NSInteger)0);
	[recentsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	PBWindowDocumentOpenCount = 0;
	XCTAssertTrue([recentsTable sendAction:recentsTable.doubleAction to:recentsTable.target]);
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)1);
	[welcome closeWelcome];

	XCTAssertFalse(welcome.window.isVisible);
	if (originalRecents)
		[NSUserDefaults.standardUserDefaults setObject:originalRecents forKey:@"PBRecentRepositories"];
	else
		[NSUserDefaults.standardUserDefaults removeObjectForKey:@"PBRecentRepositories"];
}

- (void)testRepositoryUISettingsAcceptRepositoryWithoutGitURLs
{
	PBRepositoryUISettings *settings = [[PBRepositoryUISettings alloc] initWithRepository:[PBWindowRepositoryWithoutGitURLs new]];

	XCTAssertNotNil(settings);
	XCTAssertFalse(settings.pushAfterCommit);
}

- (void)testChangedFileTreeUsesFlatFullPathsAndStatusTitles
{
	BOOL previous = PBApplicationSettings.changedFilesOnly;
	NSInteger previousSort = PBApplicationSettings.changedFilesSort;
	PBApplicationSettings.changedFilesOnly = YES;
	PBHistoryTreePresentation *presentation = [[PBHistoryTreePresentation alloc] initWithRepository:self.repository];
	PBGitTree *tree = [presentation treeForCommit:self.headCommit];
	NSArray<PBGitTree *> *children = tree.children;

	XCTAssertEqual(children.count, (NSUInteger)1);
	PBGitTree *file = children.firstObject;
	XCTAssertEqualObjects(file.fullPath, @"tracked.txt");
	XCTAssertEqualObjects([presentation toolTipForTree:file], @"tracked.txt");
	XCTAssertTrue([[presentation displayTitleForTree:file] hasPrefix:@"A  tracked.txt"]);
	PBHistoryStateCoordinator *state = [PBHistoryStateCoordinator new];
	[state saveFileBrowserSelectionFromSelectedObjects:@[ file ] hasContent:YES];
	XCTAssertEqualObjects([state treeSelectionIndexPathForChildren:(NSArray<NSObject *> *)children treeMode:YES], [NSIndexPath indexPathWithIndex:0]);
	PBApplicationSettings.changedFilesSort = 1;
	XCTAssertEqual([presentation treeForCommit:self.headCommit].children.count, (NSUInteger)1);
	PBApplicationSettings.changedFilesSort = 2;
	XCTAssertEqual([presentation treeForCommit:self.headCommit].children.count, (NSUInteger)1);
	PBApplicationSettings.changedFilesOnly = NO;
	XCTAssertFalse(PBApplicationSettings.changedFilesOnly);
	XCTAssertEqualObjects([presentation treeForCommit:self.headCommit].fullPath, self.headCommit.tree.fullPath);

	NSString *rules = @"^generated/\n# ignored\n\n.*\\.lock$";
	[self git:@[ @"config", @"--local", @"gitx.diffSuppressionPatterns", rules ] directory:self.repositoryURL];
	NSArray<NSDictionary *> *configured = [PBNativeDiffSectionSettings applyToSections:@[ @{PBNativeSectionTextKey : @"diff"} ]
																			repository:self.repository];
	XCTAssertEqualObjects(configured.firstObject[PBNativeSectionSuppressionPatternsKey], (@[ @"^generated/", @".*\\.lock$" ]));
	XCTAssertEqualObjects(configured.firstObject[PBNativeSectionDiffLayoutKey], @(PBApplicationSettings.diffLayout));

	NSError *launchError = nil;
	BOOL launched = [self.repository launchTaskWithArguments:@[ @"status", @"--porcelain" ] error:&launchError];
	XCTAssertTrue(launched, @"%@", launchError);
	PBApplicationSettings.changedFilesOnly = previous;
	PBApplicationSettings.changedFilesSort = previousSort;
}

- (void)testDialogsErrorsSettingsHookAndSuppressionBehavior
{
	[self.controller showMessageSheet:@"Message" infoText:@"Info"];
	XCTAssertEqual(PBWindowMessageCount, (NSUInteger)1);
	XCTAssertEqualObjects(PBWindowLastInfo, @"Info");
	NSError *gitxError = [NSError errorWithDomain:PBGitXErrorDomain code:1 userInfo:nil];
	self.controller.useRealErrorPresentation = YES;
	[self.controller showErrorSheet:gitxError];
	XCTAssertEqual(PBWindowErrorMessageCount, (NSUInteger)1);
	[self.controller showErrorSheet:self.repository.testError];
	self.controller.useRealErrorPresentation = NO;

	PBWindowHookResponse = NSModalResponseCancel;
	PBWindowCommitControllerSpy *commitController = [[PBWindowCommitControllerSpy alloc] initWithRepository:self.repository superController:self.controller];
	[self.controller setValue:commitController forKey:@"_commitViewController"];
	[self.controller showCommitHookFailedSheet:@"Hook" infoText:@"Failed" commitController:commitController];
	PBWindowHookResponse = NSModalResponseOK;
	[self.controller showCommitHookFailedSheet:@"Hook" infoText:@"Failed" commitController:commitController];
	XCTAssertEqual(PBWindowHookCount, (NSUInteger)2);
	XCTAssertEqual(commitController.forceCommitCount, (NSUInteger)1);

	self.controller.useRealConfirmation = YES;
	__block NSUInteger actionCount = 0;
	NSAlert *alert = [NSAlert new];
	PBWindowAlertResponse = NSAlertSecondButtonReturn;
	XCTAssertFalse([self.controller confirmDialog:alert
							suppressionIdentifier:@"Test Dialog"
										forAction:^{
											actionCount++;
										}]);
	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertSuppressionState = NSControlStateValueOn;
	XCTAssertTrue([self.controller confirmDialog:alert
						   suppressionIdentifier:@"Test Dialog"
									   forAction:^{
										   actionCount++;
									   }]);
	XCTAssertTrue([PBGitDefaults isDialogWarningSuppressedForDialog:@"Test Dialog"]);
	XCTAssertTrue([self.controller confirmDialog:alert
						   suppressionIdentifier:@"Test Dialog"
									   forAction:^{
										   actionCount++;
									   }]);
	XCTAssertEqual(actionCount, (NSUInteger)2);

	PBWindowAlertResponse = NSAlertSecondButtonReturn;
	[self.controller showRepositorySettings:self];
	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	[self.controller showRepositorySettings:self];
}

- (void)testFocusRefreshSnapshotsPreferenceGenerationAndCancellation
{
	PBWindowUseSnapshotTaskFake = YES;
	PBWindowSnapshotData = [@"snapshot-a" dataUsingEncoding:NSUTF8StringEncoding];
	[NSUserDefaults.standardUserDefaults setObject:@YES forKey:@"PBRefreshOnApplicationFocus"];
	[self.controller refreshPreferenceDidChange:nil];
	[self pumpRunLoopFor:0.1];
	NSUInteger baseline = self.controller.refreshCount;
	[self.controller applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:NSApp]];
	[self pumpRunLoopFor:0.1];
	XCTAssertEqual(self.controller.refreshCount, baseline);

	PBWindowSnapshotData = [@"snapshot-b" dataUsingEncoding:NSUTF8StringEncoding];
	[self.controller refreshIfRepositoryChangedSinceLastActivation];
	[self pumpRunLoopFor:0.1];
	XCTAssertGreaterThan(self.controller.refreshCount, baseline);

	NSUInteger changedCount = self.controller.refreshCount;
	PBWindowSnapshotData = [@"snapshot-c" dataUsingEncoding:NSUTF8StringEncoding];
	[self.controller refreshIfRepositoryChangedSinceLastActivation];
	[NSUserDefaults.standardUserDefaults setObject:@NO forKey:@"PBRefreshOnApplicationFocus"];
	[self.controller refreshPreferenceDidChange:nil];
	[self pumpRunLoopFor:0.1];
	XCTAssertEqual(self.controller.refreshCount, changedCount);

	PBWindowSnapshotError = self.repository.testError;
	[NSUserDefaults.standardUserDefaults setObject:@YES forKey:@"PBRefreshOnApplicationFocus"];
	[self.controller refreshPreferenceDidChange:nil];
	[self pumpRunLoopFor:0.1];
	XCTAssertGreaterThan(self.controller.refreshCount, changedCount);
}

@end

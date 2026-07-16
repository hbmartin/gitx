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
#import "PBCreateBranchSheet.h"
#import "PBCreateTagSheet.h"
#import "PBDiffWindowController.h"
#import "PBGitCommit.h"
#import "PBGitCommitController.h"
#import "PBGitDefaults.h"
#import "PBGitHistoryController.h"
#import "PBGitHistoryList.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitRevSpecifier.h"
#import "PBGitSidebarController.h"
#import "PBGitStash.h"
#import "PBGitWindowController.h"
#import "PBGitXMessageSheet.h"
#import "PBError.h"
#import "PBRemoteProgressSheet.h"
#import "PBSourceViewItem.h"
#import "PBTask.h"
#import "PBTerminalUtil.h"
#import "PBViewController.h"

@interface PBGitWindowController (WindowControllerTests)
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)refreshPreferenceDidChange:(nullable NSNotification *)notification;
- (void)refreshIfRepositoryChangedSinceLastActivation;
- (void)removeAllContentSubViews;
- (void)updateStatus;
- (nullable NSArray<NSURL *> *)selectedURLsFromSender:(id)sender;
- (nullable id<PBGitRefish>)refishForSender:(id)sender refishTypes:(nullable NSArray<NSString *> *)types;
- (nullable PBGitRef *)selectedRef;
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

@interface PBWindowProgressSheet : PBRemoteProgressSheet
@end

@implementation PBWindowProgressSheet

- (void)beginProgressSheetForBlock:(PBProgressSheetExecutionHandler)executionBlock completionHandler:(void (^)(NSError *))completionHandler
{
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

@interface PBWindowRepositorySpy : PBGitRepository
@property (nonatomic, strong) NSMutableArray<NSString *> *operations;
@property (nonatomic, copy, nullable) NSString *failingOperation;
@property (nonatomic, strong) NSError *testError;
@property (nonatomic, copy) NSArray<NSString *> *testRemotes;
@property (nonatomic, strong, nullable) PBGitRef *trackingRef;
@property (nonatomic, strong, nullable) PBWindowSubmodule *testSubmodule;
@property (nonatomic, copy, nullable) NSURL *testWorkingDirectoryURL;
@property (nonatomic) BOOL testBare;
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
	[self setValue:[[NSClassFromString(@"PBRepositoryFocusRefreshTracker") alloc] init] forKey:@"_focusRefreshTracker"];
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
}

+ (void)tearDown
{
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

- (void)pumpRunLoopFor:(NSTimeInterval)duration
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
	while ([deadline timeIntervalSinceNow] > 0) {
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	}
}

- (void)testRealNibLifecycleContentSwitchingStatusAndValidation
{
	PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] init];
	[document setValue:self.repository forKey:@"_repository"];
	PBGitWindowController *controller = [[PBGitWindowController alloc] init];
	controller.document = document;
	NSWindow *window = controller.window;

	XCTAssertNotNil(window);
	PBGitSidebarController *sidebar = [controller valueForKey:@"_sidebarController"];
	PBGitHistoryController *history = [controller valueForKey:@"_historyViewController"];
	PBGitCommitController *commit = [controller valueForKey:@"_commitViewController"];
	XCTAssertNotNil(sidebar);
	XCTAssertNotNil(history);
	XCTAssertNotNil(commit);
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
	content.status = @"Busy";
	content.isBusy = YES;
	[self.controller changeContentController:content];
	XCTAssertEqual(content.updateCount, (NSUInteger)1);
	XCTAssertEqualObjects(status.stringValue, @"Busy");
	XCTAssertFalse(progress.hidden);

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

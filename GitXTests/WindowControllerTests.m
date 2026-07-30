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
#import "PBGitSidebarControllerCompatibility.h"
#import "PBGitStash.h"
#import "PBGitTree.h"
#import "PBGitWindowControllerCompatibility.h"
#import "PBGitXMessageSheet.h"
#import "PBError.h"
#import "PBFileChangesTableView.h"
#import "GLFileView.h"
#import "PBNativeContentView.h"
#import "PBRemoteProgressSheet.h"
#import "PBSourceViewBadge.h"
#import "PBSourceViewItem.h"
#import "PBSourceViewItems.h"
#import "PBSidebarList.h"
#import "PBSidebarTableViewCell.h"
#import "PBTask.h"
#import "PBTerminalUtil.h"
#import "PBPrefsWindowController.h"
#import "PBViewController.h"

@implementation PBHistoryWindowControllerTestBase
@end

@interface PBRepositoryToolbarController : NSObject
- (instancetype)initWithWindowController:(PBGitWindowController *)windowController;
- (void)install;
- (void)updateWithStatus:(NSString *)status busy:(BOOL)busy baseWindowTitle:(NSString *)baseWindowTitle;
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar;
- (nullable NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag;
- (void)attentionUnseenDidChange:(NSNotification *)notification;
@end

@interface PBRepositorySettingsStore : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (NSString *)stringForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (BOOL)setString:(NSString *)value forKey:(NSString *)key error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setBool:(BOOL)value forKey:(NSString *)key error:(NSError *_Nullable *_Nullable)error;
- (NSString *)detectedPrimaryBranch;
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

@interface PBRepositoryOpenCoordinator : NSObject
+ (instancetype)shared;
- (void)openURLs:(NSArray<NSURL *> *)urls
	sourceWindow:(nullable NSWindow *)sourceWindow
	  completion:(void (^)(NSArray<NSDocument *> *documents, NSArray<NSError *> *errors))completion;
@end

@interface PBGitSidebarController (WindowControllerTests)
- (void)reloadSidebarAfterReferencesChange;
- (void)reloadSidebarPresentation;
- (void)repositorySettingsDidChange:(NSNotification *)notification;
- (nullable PBSourceViewItem *)selectedItem;
- (nullable PBSourceViewItem *)itemForRev:(PBGitRevSpecifier *)rev;
- (nullable PBSourceViewItem *)addRevSpec:(PBGitRevSpecifier *)rev;
- (void)removeRevSpec:(PBGitRevSpecifier *)rev;
- (void)openSubmoduleFromMenuItem:(NSMenuItem *)menuItem;
- (void)openSubmoduleAtURL:(NSURL *)submoduleURL;
- (void)doubleClicked:(id)sender;
- (void)toggleBranchSort:(id)sender;
- (void)outlineViewSelectionDidChange:(NSNotification *)notification;
- (nullable NSView *)outlineView:(NSOutlineView *)outlineView
			  viewForTableColumn:(nullable NSTableColumn *)tableColumn
							item:(PBSourceViewItem *)item;
- (nullable NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isGroupItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldShowOutlineCellForItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView
	shouldEditTableColumn:(nullable NSTableColumn *)tableColumn
					 item:(id)item;
- (nullable id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item;
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item;
- (nullable id)outlineView:(NSOutlineView *)outlineView
	objectValueForTableColumn:(nullable NSTableColumn *)tableColumn
					   byItem:(id)item;
- (void)expandCollapseItem:(NSNotification *)notification;
- (void)updateActionMenu;
- (void)updateRemoteControls;
- (void)addMenuItemsForRef:(nullable PBGitRef *)ref toMenu:(NSMenu *)menu;
- (void)addMenuItemsForSubmodule:(nullable PBSourceViewGitSubmoduleItem *)submodule toMenu:(NSMenu *)menu;
- (void)showForgeAttention:(nullable id)sender;
- (void)attentionUnseenDidChange:(NSNotification *)notification;
- (void)forgeAccessDidChange:(NSNotification *)notification;
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
- (void)handleSuccessfulPushOutput:(NSString *)output
						repository:(PBGitRepository *)repository
							remote:(nullable PBGitRef *)remote
				  presentingWindow:(nullable NSWindow *)window;
- (nullable NSURL *)firstHTTPURLInOutput:(NSString *)output;
- (nullable NSURL *)webURLForRemoteURL:(NSString *)remoteURL branch:(NSString *)branch sha:(NSString *)sha;
- (void)viewRemoteForRepository:(PBGitRepository *)repository presentingWindow:(nullable NSWindow *)window;
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
- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize;
@end

@interface PBApplicationSettings : NSObject
@property (class) BOOL repositoryStatusBarVisible;
+ (BOOL)changedFilesOnly;
+ (void)setChangedFilesOnly:(BOOL)value;
+ (NSInteger)changedFilesSort;
+ (void)setChangedFilesSort:(NSInteger)value;
+ (NSInteger)branchSort;
+ (void)setBranchSort:(NSInteger)value;
+ (NSInteger)diffLayout;
@end

@interface PBNativeDiffSectionSettings : NSObject
+ (NSArray<NSDictionary *> *)applyToSections:(NSArray<NSDictionary *> *)sections repository:(PBGitRepository *)repository;
@end

@interface PBWindowHistoryTreeLogStub : PBGitTree
@end

@interface PBWindowRepositoryWithoutGitURLs : PBGitRepository
@property (nonatomic, copy, nullable) NSString *testCommonGitDirectoryOutput;
@property (nonatomic, strong, nullable) NSURL *testGitURL;
@property (nonatomic, strong, nullable) NSURL *testWorkingDirectoryURL;
@end

@interface PBWindowRepositoryWithGitURLOnly : PBGitRepository
@property (nonatomic, strong) NSURL *testGitURL;
@end

@interface PBWelcomeWindowController : NSWindowController
+ (instancetype)shared;
- (void)show;
- (void)searchChanged:(nullable id)sender;
- (void)closeWelcome;
@end

@interface PBRepositoryUISettings : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
@property (nonatomic) BOOL pushAfterCommit;
@property (nonatomic) BOOL hideContainedBranches;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *sidebarVisibility;
@end

@interface PBSourceViewBadge (WindowControllerTests)
+ (NSColor *)badgeHighlightColor;
+ (NSColor *)badgeBackgroundColor;
+ (NSColor *)badgeColorForCell:(NSTableCellView *)cell;
+ (NSColor *)badgeTextColorForCell:(NSTableCellView *)cell;
+ (NSImage *)badge:(NSString *)badge forCell:(NSTableCellView *)cell;
@end

@interface PBSourceViewBadgeTestWindow : NSWindow
@property (nonatomic) BOOL testMainWindow;
@property (nonatomic) BOOL testKeyWindow;
@end

@interface PBSourceViewBadgeTestCell : NSTableCellView
@property (nonatomic) NSBackgroundStyle testBackgroundStyle;
@property (nonatomic) NSWindow *testWindow;
@end

@implementation PBSourceViewBadgeTestWindow

- (BOOL)isMainWindow
{
	return self.testMainWindow;
}

- (BOOL)isKeyWindow
{
	return self.testKeyWindow;
}

@end

@implementation PBSourceViewBadgeTestCell

- (NSBackgroundStyle)backgroundStyle
{
	return self.testBackgroundStyle;
}

- (NSWindow *)window
{
	return self.testWindow;
}

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

- (nullable NSString *)outputOfTaskWithArguments:(nullable NSArray<NSString *> *)arguments
										   error:(NSError *_Nullable *_Nullable)error
{
	return self.testCommonGitDirectoryOutput ?: @"";
}

- (nullable NSURL *)gitURL
{
	return self.testGitURL;
}

- (nullable NSURL *)workingDirectoryURL
{
	return self.testWorkingDirectoryURL;
}

@end

@implementation PBWindowRepositoryWithGitURLOnly

- (nullable NSString *)outputOfTaskWithArguments:(nullable NSArray<NSString *> *)arguments
										   error:(NSError *_Nullable *_Nullable)error
{
	return @".git/common\n";
}

- (nullable NSURL *)gitURL
{
	return self.testGitURL;
}

- (nullable NSURL *)workingDirectoryURL
{
	return nil;
}

@end

@interface PBWindowRemoteWithoutNameRef : PBGitRef
@end

@implementation PBWindowRemoteWithoutNameRef
- (BOOL)isRemote
{
	return YES;
}
- (NSString *)remoteName
{
	return nil;
}
@end

@interface RepositoryUISettingsTests : XCTestCase
@end

@implementation RepositoryUISettingsTests

- (void)testRepositoryUISettingsUsesGitURLForRelativeCommonDirectoryWithoutWorkingDirectory
{
	id originalSettings = [NSUserDefaults.standardUserDefaults objectForKey:@"PBRepositoryUISettings"];
	PBWindowRepositoryWithGitURLOnly *repository = [PBWindowRepositoryWithGitURLOnly new];
	repository.testGitURL = [NSURL fileURLWithPath:@"/tmp/GitXGitURLOnly" isDirectory:YES];
	PBRepositoryUISettings *settings = [[PBRepositoryUISettings alloc] initWithRepository:repository];

	settings.pushAfterCommit = YES;
	NSURL *commonDirectory = [repository.testGitURL URLByAppendingPathComponent:@".git/common" isDirectory:YES];
	NSString *repositoryKey = commonDirectory.standardizedURL.URLByResolvingSymlinksInPath.path;
	NSDictionary *allSettings = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"PBRepositoryUISettings"];
	XCTAssertEqualObjects(allSettings[repositoryKey][@"pushAfterCommit"], @YES);
	if (originalSettings)
		[NSUserDefaults.standardUserDefaults setObject:originalSettings forKey:@"PBRepositoryUISettings"];
	else
		[NSUserDefaults.standardUserDefaults removeObjectForKey:@"PBRepositoryUISettings"];
}

- (void)testRepositoryUISettingsFallsBackToRootForRelativeCommonDirectoryWithoutRepositoryURLs
{
	id originalSettings = [NSUserDefaults.standardUserDefaults objectForKey:@"PBRepositoryUISettings"];
	PBWindowRepositoryWithoutGitURLs *repository = [PBWindowRepositoryWithoutGitURLs new];
	repository.testCommonGitDirectoryOutput = @".git/common";
	PBRepositoryUISettings *settings = [[PBRepositoryUISettings alloc] initWithRepository:repository];

	settings.pushAfterCommit = YES;
	NSString *repositoryKey = [NSURL fileURLWithPath:@"/.git/common" isDirectory:YES].standardizedURL.URLByResolvingSymlinksInPath.path;
	NSDictionary *allSettings = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"PBRepositoryUISettings"];
	XCTAssertEqualObjects(allSettings[repositoryKey][@"pushAfterCommit"], @YES);
	if (originalSettings)
		[NSUserDefaults.standardUserDefaults setObject:originalSettings forKey:@"PBRepositoryUISettings"];
	else
		[NSUserDefaults.standardUserDefaults removeObjectForKey:@"PBRepositoryUISettings"];
}

@end

@interface PBGitWindowController (WindowControllerTests)
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)refreshPreferenceDidChange:(nullable NSNotification *)notification;
- (void)refreshIfRepositoryChangedSinceLastActivation;
- (void)updateStatus;
- (nullable NSArray<NSURL *> *)selectedURLsFromSender:(id)sender;
- (nullable id<PBGitRefish>)refishForSender:(id)sender refishTypes:(nullable NSArray<NSString *> *)types;
- (nullable PBGitRef *)selectedRef;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
			 remoteTitle:(NSString *)remoteTitle
			  plainTitle:(NSString *)plainTitle;
- (IBAction)toolbarFetch:(id)sender;
- (IBAction)toolbarPull:(id)sender;
- (IBAction)toolbarPush:(id)sender;
- (IBAction)viewRemote:(id)sender;
- (IBAction)viewForgeRepository:(id)sender;
- (IBAction)viewForgeCheckedOutRevision:(id)sender;
- (IBAction)viewForgeSelectedCommit:(id)sender;
- (IBAction)viewForgeSelectedComparison:(id)sender;
- (IBAction)showForgePullRequestOrIssue:(id)sender;
- (IBAction)toggleRepositoryStatusBar:(nullable id)sender;
- (void)showForgeStatusDetails:(nullable id)sender;
- (void)presentForgeRecoveryStatusDetailsWithCopyURL:(NSURL *)copyURL
									   revealHandler:(void (^)(NSURL *copyURL))revealHandler;
@end

static NSModalResponse PBWindowAlertResponse;
static NSControlStateValue PBWindowAlertSuppressionState;
static NSUInteger PBWindowAlertSheetCount;
static NSUInteger PBWindowAlertAppModalCount;
static NSMutableArray<NSAlert *> *PBWindowPresentedAlerts;
static void (^PBWindowAlertPresentationHook)(NSAlert *);
static NSModalResponse PBWindowAddRemoteResponse;
static NSModalResponse PBWindowCreateBranchResponse;
static NSModalResponse PBWindowCreateTagResponse;
static NSModalResponse PBWindowHookResponse;
static NSUInteger PBWindowWorkspaceOpenCount;
static NSUInteger PBWindowWorkspaceRevealCount;
static NSMutableArray<NSURL *> *PBWindowWorkspaceOpenedURLs;
static NSUInteger PBWindowDocumentOpenCount;
static NSMutableArray<NSURL *> *PBWindowDocumentOpenedURLs;
static NSMutableDictionary<NSString *, NSError *> *PBWindowDocumentOpenErrorsByPath;

static NSString *PBWindowResolvedPath(NSURL *url)
{
	return url.URLByResolvingSymlinksInPath.standardizedURL.path;
}
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
- (void)pb_window_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^_Nullable)(NSModalResponse returnCode))handler;
- (NSModalResponse)pb_window_runModal;
@end

@implementation NSAlert (WindowControllerTests)

- (void)pb_window_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^_Nullable)(NSModalResponse returnCode))handler
{
	PBWindowAlertSheetCount++;
	[PBWindowPresentedAlerts addObject:self];
	if (PBWindowAlertPresentationHook) PBWindowAlertPresentationHook(self);
	self.suppressionButton.state = PBWindowAlertSuppressionState;
	if (handler) handler(PBWindowAlertResponse);
}

- (NSModalResponse)pb_window_runModal
{
	PBWindowAlertAppModalCount++;
	[PBWindowPresentedAlerts addObject:self];
	if (PBWindowAlertPresentationHook) PBWindowAlertPresentationHook(self);
	return PBWindowAlertResponse;
}

@end

@interface NSWorkspace (WindowControllerTests)
- (BOOL)pb_window_openURL:(NSURL *)url;
- (void)pb_window_openURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration completionHandler:(void (^)(NSRunningApplication *_Nullable app, NSError *_Nullable error))completionHandler;
- (void)pb_window_activateFileViewerSelectingURLs:(NSArray<NSURL *> *)fileURLs;
@end

@implementation NSWorkspace (WindowControllerTests)

- (BOOL)pb_window_openURL:(NSURL *)url
{
	PBWindowWorkspaceOpenCount++;
	[PBWindowWorkspaceOpenedURLs addObject:url];
	return YES;
}

- (void)pb_window_openURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration completionHandler:(void (^)(NSRunningApplication *_Nullable app, NSError *_Nullable error))completionHandler
{
	PBWindowWorkspaceOpenCount++;
	[PBWindowWorkspaceOpenedURLs addObject:url];
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
	[PBWindowDocumentOpenedURLs addObject:url];
	completionHandler(nil, NO, PBWindowDocumentOpenErrorsByPath[PBWindowResolvedPath(url)]);
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
+ (void)pb_window_beginWithMessageText:(NSString *)message infoText:(NSString *)info windowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler;
@end

@implementation PBCommitHookFailedSheet (WindowControllerTests)

+ (void)pb_window_beginWithMessageText:(NSString *)message infoText:(NSString *)info windowController:(PBGitWindowController *)windowController completionHandler:(RJSheetCompletionHandler)handler
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
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) GTRepository *parentRepository;
@end
@implementation PBWindowSubmodule
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
@property (nonatomic, copy, nullable) NSArray<NSString *> *testRemotes;
@property (nonatomic) BOOL hidesProjectName;
@property (nonatomic, strong, nullable) PBGitRef *trackingRef;
@property (nonatomic, strong, nullable) PBWindowSubmodule *testSubmodule;
@property (nonatomic, copy, nullable) NSURL *testWorkingDirectoryURL;
@property (nonatomic) BOOL testBare;
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
- (void)reloadRefs
{
	self.reloadRefsCount++;
	[super reloadRefs];
}
- (NSArray<NSString *> *)remotes
{
	return self.testRemotes;
}
- (NSString *)projectName
{
	return self.hidesProjectName ? nil : super.projectName;
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

@interface PBWindowCommitStub : PBGitCommit
@property (nonatomic, copy) NSString *testSHA;
- (instancetype)initWithSHA:(NSString *)SHA;
@end

@implementation PBWindowCommitStub
- (instancetype)initWithSHA:(NSString *)SHA
{
	self = [super init];
	if (!self) return nil;
	_testSHA = [SHA copy];
	return self;
}
- (NSString *)SHA
{
	return self.testSHA;
}
@end

@interface PBWindowOutlineView : NSOutlineView
@property (nonatomic, strong, nullable) id testItem;
@property (nonatomic, strong, nullable) NSTableRowView *testRowView;
@property (nonatomic) NSInteger testItemRow;
@property (nonatomic) NSUInteger deselectAllCount;
@property (nonatomic) NSUInteger selectRowsCount;
@end
@implementation PBWindowOutlineView
- (id)itemAtRow:(NSInteger)row
{
	return self.testItem;
}
- (NSInteger)rowForItem:(id)item
{
	return self.testItemRow;
}
- (NSTableRowView *)rowViewAtRow:(NSInteger)row makeIfNecessary:(BOOL)makeIfNecessary
{
	return self.testRowView;
}
- (void)deselectAll:(nullable id)sender
{
	self.deselectAllCount++;
	[super deselectAll:sender];
}
- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend
{
	self.selectRowsCount++;
	[super selectRowIndexes:indexes byExtendingSelection:extend];
}
@end

@interface PBWindowHistoryMenuSpy : PBGitHistoryController
@property (nonatomic, copy) NSArray<NSMenuItem *> *testMenuItems;
@end

@implementation PBWindowHistoryMenuSpy
- (NSArray<NSMenuItem *> *)menuItemsForRef:(PBGitRef *)ref
{
	NSMutableArray<NSMenuItem *> *items = [NSMutableArray arrayWithCapacity:self.testMenuItems.count];
	for (NSMenuItem *item in self.testMenuItems) [items addObject:item.copy];
	return items;
}
@end

@interface PBWindowAddRemoteResponder : NSResponder
@property (nonatomic) NSUInteger addRemoteCount;
@end

@implementation PBWindowAddRemoteResponder
- (void)addRemote:(id)sender
{
	self.addRemoteCount++;
}
@end

@interface PBWindowSidebarSpy : PBGitSidebarController
@property (nonatomic, strong) PBWindowOutlineView *testSourceView;
@property (nonatomic, strong) PBSourceViewItem *testRemotes;
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
@property (nonatomic, strong, nullable) PBGitRef *forcedSelectedRef;
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
@property (nonatomic) BOOL interceptContentChange;
@property (nonatomic) NSUInteger contentChangeCount;
@property (nonatomic, strong, nullable) PBViewController *lastContentController;
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
- (PBGitRef *)selectedRef
{
	return self.forcedSelectedRef ?: super.selectedRef;
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
- (void)changeContentController:(nullable PBViewController *)newContentController
{
	if (!self.interceptContentChange) return [super changeContentController:newContentController];
	self.contentChangeCount++;
	self.lastContentController = newContentController;
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
	PBSwapInstanceMethods(NSAlert.class, @selector(runModal), @selector(pb_window_runModal));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(openURL:), @selector(pb_window_openURL:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(openURL:configuration:completionHandler:), @selector(pb_window_openURL:configuration:completionHandler:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(activateFileViewerSelectingURLs:), @selector(pb_window_activateFileViewerSelectingURLs:));
	PBSwapInstanceMethods(NSDocumentController.class, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(pb_window_openDocumentWithContentsOfURL:display:completionHandler:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithMessage:info:windowController:), @selector(pb_window_beginSheetWithMessage:info:windowController:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithError:windowController:), @selector(pb_window_beginSheetWithError:windowController:));
	PBSwapClassMethods(PBCommitHookFailedSheet.class, @selector(beginWithMessageText:infoText:windowController:completionHandler:), @selector(pb_window_beginWithMessageText:infoText:windowController:completionHandler:));
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
	PBSwapClassMethods(PBCommitHookFailedSheet.class, @selector(beginWithMessageText:infoText:windowController:completionHandler:), @selector(pb_window_beginWithMessageText:infoText:windowController:completionHandler:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithError:windowController:), @selector(pb_window_beginSheetWithError:windowController:));
	PBSwapClassMethods(PBGitXMessageSheet.class, @selector(beginSheetWithMessage:info:windowController:), @selector(pb_window_beginSheetWithMessage:info:windowController:));
	PBSwapInstanceMethods(NSDocumentController.class, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(pb_window_openDocumentWithContentsOfURL:display:completionHandler:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(activateFileViewerSelectingURLs:), @selector(pb_window_activateFileViewerSelectingURLs:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(openURL:configuration:completionHandler:), @selector(pb_window_openURL:configuration:completionHandler:));
	PBSwapInstanceMethods(NSWorkspace.class, @selector(openURL:), @selector(pb_window_openURL:));
	PBSwapInstanceMethods(NSAlert.class, @selector(runModal), @selector(pb_window_runModal));
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
	PBWindowAlertSheetCount = 0;
	PBWindowAlertAppModalCount = 0;
	PBWindowPresentedAlerts = [NSMutableArray array];
	PBWindowAlertPresentationHook = nil;
	PBWindowAddRemoteResponse = NSModalResponseCancel;
	PBWindowCreateBranchResponse = NSModalResponseCancel;
	PBWindowCreateTagResponse = NSModalResponseCancel;
	PBWindowHookResponse = NSModalResponseCancel;
	PBWindowWorkspaceOpenCount = 0;
	PBWindowWorkspaceRevealCount = 0;
	PBWindowWorkspaceOpenedURLs = [NSMutableArray array];
	PBWindowDocumentOpenCount = 0;
	PBWindowDocumentOpenedURLs = [NSMutableArray array];
	PBWindowDocumentOpenErrorsByPath = [NSMutableDictionary dictionary];
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
	PBWindowDocumentOpenedURLs = nil;
	PBWindowDocumentOpenErrorsByPath = nil;
	PBWindowPresentedAlerts = nil;
	PBWindowAlertPresentationHook = nil;
	PBWindowWorkspaceOpenedURLs = nil;
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

- (void)configureForgeRemotes:(NSDictionary<NSString *, NSString *> *)remotes
{
	NSArray<NSString *> *existing = [[self git:@[ @"remote" ] directory:self.repositoryURL]
		componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
	for (NSString *name in remotes) {
		if ([existing containsObject:name])
			[self git:@[ @"remote", @"set-url", name, remotes[name] ] directory:self.repositoryURL];
		else
			[self git:@[ @"remote", @"add", name, remotes[name] ] directory:self.repositoryURL];
	}
	self.repository.testRemotes = [remotes.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
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

- (void)attachScreenshotOfView:(NSView *)view name:(NSString *)name
{
	[view layoutSubtreeIfNeeded];
	NSBitmapImageRep *representation = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
	XCTAssertNotNil(representation);
	if (!representation) return;
	[view cacheDisplayInRect:view.bounds toBitmapImageRep:representation];
	NSImage *screenshot = [[NSImage alloc] initWithSize:view.bounds.size];
	[screenshot addRepresentation:representation];
	XCTAttachment *attachment = [XCTAttachment attachmentWithImage:screenshot];
	attachment.name = name;
	attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
	[self addAttachment:attachment];
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

- (void)testRealNibLifecycleContentSwitchingStatusAndValidation
{
	[self configureForgeRemotes:@{@"origin" : @"https://github.com/hbmartin/gitx.git"}];
	PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] init];
	[document setValue:self.repository forKey:@"_repository"];
	PBGitWindowController *controller = [[PBGitWindowController alloc] init];
	controller.document = document;
	NSWindow *window = controller.window;

	XCTAssertNotNil(window);
	PBGitSidebarController *sidebar = [controller valueForKey:@"_sidebarController"];
	PBGitHistoryController *history = [controller valueForKey:@"_historyViewController"];
	XCTAssertNotNil(sidebar);
	XCTAssertNotNil(history);
	[sidebar reloadSidebarAfterReferencesChange];
	XCTAssertEqualObjects(window.representedURL, self.repository.workingDirectoryURL);
	XCTAssertEqualObjects([controller valueForKeyPath:@"jumpToCheckedOutBranchButton.accessibilityIdentifier"], @"JumpToCheckedOutBranchButton");

	NSMenuItem *commitItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Commit", nil) action:@selector(showUncommittedChanges:) keyEquivalent:@""];
	NSMenuItem *historyItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"History", nil) action:@selector(showHistoryView:) keyEquivalent:@""];
	XCTAssertTrue([controller validateMenuItem:commitItem]);
	XCTAssertEqual(commitItem.state, NSControlStateValueOff);
	XCTAssertTrue([controller validateMenuItem:historyItem]);
	XCTAssertEqual(historyItem.state, NSControlStateValueOn);
	XCTAssertTrue([controller validateMenuItem:[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Other", nil) action:@selector(copy:) keyEquivalent:@""]]);
	NSMenuItem *statusBarItem = [[NSMenuItem alloc] initWithTitle:@"Repository Status Bar"
														   action:@selector(toggleRepositoryStatusBar:)
													keyEquivalent:@""];
	BOOL originalStatusBarVisibility = PBApplicationSettings.repositoryStatusBarVisible;
	XCTAssertTrue([controller validateMenuItem:statusBarItem]);
	XCTAssertEqual(statusBarItem.state,
				   originalStatusBarVisibility ? NSControlStateValueOn : NSControlStateValueOff);
	[controller toggleRepositoryStatusBar:self];
	XCTAssertNotEqual(PBApplicationSettings.repositoryStatusBarVisible, originalStatusBarVisibility);
	[controller toggleRepositoryStatusBar:self];
	XCTAssertEqual(PBApplicationSettings.repositoryStatusBarVisible, originalStatusBarVisibility);
	[[NSNotificationCenter defaultCenter] postNotificationName:@"PBRepositoryRemoteOperationDidSucceedNotification"
														object:self.repository
													  userInfo:@{@"operation" : @"fetch"}];
	[[NSNotificationCenter defaultCenter] postNotificationName:@"PBRepositoryRemoteOperationDidSucceedNotification"
														object:self.repository
													  userInfo:@{@"operation" : @"push"}];
	[controller showForgeStatusDetails:self];
	XCTAssertEqualObjects(PBWindowPresentedAlerts.lastObject.messageText, @"Sign In Required");
	NSURL *recoveryCopyURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
														stringByAppendingPathComponent:[NSString stringWithFormat:@"Forge-recovery-%@.sqlite3", NSUUID.UUID.UUIDString]]];
	__block NSURL *revealedRecoveryCopyURL = nil;
	[controller presentForgeRecoveryStatusDetailsWithCopyURL:recoveryCopyURL
											   revealHandler:^(NSURL *copyURL) {
												   revealedRecoveryCopyURL = copyURL;
											   }];
	NSAlert *recoveryAlert = PBWindowPresentedAlerts.lastObject;
	XCTAssertEqualObjects(recoveryAlert.messageText, @"Forge Data Unavailable");
	XCTAssertTrue([recoveryAlert.informativeText containsString:recoveryCopyURL.lastPathComponent]);
	XCTAssertEqualObjects([recoveryAlert.buttons valueForKey:@"title"], (@[ @"Reveal in Finder", @"OK" ]));
	XCTAssertEqualObjects(revealedRecoveryCopyURL, recoveryCopyURL);

	[controller changeContentController:history];
	history.status = @"History ready";
	history.isBusy = YES;
	[controller updateStatus];
	XCTAssertEqualObjects([[controller valueForKey:@"statusField"] stringValue], @"History ready");
	XCTAssertFalse([[controller valueForKey:@"progressIndicator"] isHidden]);
	[controller showHistoryView:self];
	XCTAssertFalse(controller.isUncommittedChangesSelected);
	PBWindowSendObject(controller, @selector(changeContentController:), nil);

	[controller setHistorySearch:@"initial" mode:PBHistorySearchModeBasic];
	[controller synchronizeWindowTitleWithDocumentName];
	[controller showHistoryView:self];
	XCTAssertFalse(controller.isUncommittedChangesSelected);
	[controller windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:window]];
	XCTAssertNil(controller.sidebarViewController);
	XCTAssertNil(controller.historyViewController);
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
	[self.controller changeContentController:content];
	XCTAssertEqual(content.updateCount, (NSUInteger)1);
	XCTAssertEqual(content.view.superview, container);
	XCTAssertFalse(content.view.hidden);
	XCTAssertTrue(NSEqualRects(content.view.frame, container.bounds));
	XCTAssertEqual(container.subviews.count, (NSUInteger)1);
	XCTAssertEqualObjects(status.stringValue, @"Busy");
	XCTAssertFalse(progress.hidden);

	[self.controller changeContentController:secondContent];
	XCTAssertEqual(secondContent.updateCount, (NSUInteger)1);
	XCTAssertNil(content.view.superview);
	XCTAssertTrue(content.view.hidden);
	XCTAssertEqual(secondContent.view.superview, container);
	XCTAssertFalse(secondContent.view.hidden);
	XCTAssertEqual(container.subviews.count, (NSUInteger)1);
	XCTAssertEqual(container.subviews.firstObject, secondContent.view);

	[self.controller changeContentController:content];
	XCTAssertEqual(content.updateCount, (NSUInteger)1);
	XCTAssertEqual(secondContent.updateCount, (NSUInteger)1);
	XCTAssertNil(secondContent.view.superview);
	XCTAssertTrue(secondContent.view.hidden);
	XCTAssertFalse(content.view.hidden);
	XCTAssertEqualObjects(status.stringValue, @"Busy");
	XCTAssertFalse(self.controller.isUncommittedChangesSelected);

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
	[self.controller showUncommittedChanges:self];
	[self.controller showHistoryView:self];
	XCTAssertEqual(sidebar.branchSelectionCount, (NSUInteger)2);
	[self.controller jumpToCheckedOutBranch:self];
	XCTAssertEqual(sidebar.branchSelectionCount, (NSUInteger)3);
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
	PBGitRef *untrackedBranch = [PBGitRef refFromString:@"refs/heads/untracked"];
	outline.testItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:untrackedBranch]];
	NSMenuItem *plainFetch = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	self.repository.trackingRef = nil;
	XCTAssertFalse([self.controller validateMenuItem:plainFetch remoteTitle:@"Fetch “%@”" plainTitle:@"Fetch"]);
	XCTAssertEqualObjects(plainFetch.title, @"Fetch");
	PBWindowRemoteWithoutNameRef *unnamedRemote = [[PBWindowRemoteWithoutNameRef alloc] initWithString:@"refs/remotes/origin/main"];
	self.controller.forcedSelectedRef = unnamedRemote;
	NSMenuItem *unnamedRemoteFetch = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:unnamedRemoteFetch remoteTitle:@"Fetch “%@”" plainTitle:@"Fetch"]);
	XCTAssertEqualObjects(unnamedRemoteFetch.title, @"Fetch “(null)”");
	self.controller.forcedSelectedRef = nil;
	self.repository.trackingRef = self.remoteBranchRef;

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

- (void)testSidebarMenusSortingAndReferenceRemoval
{
	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	(void)sidebar.view;
	PBGitRevSpecifier *branchRevision = [[PBGitRevSpecifier alloc] initWithRef:self.branchRef];
	PBSourceViewItem *branchItem = [sidebar itemForRev:branchRevision];
	XCTAssertNotNil(branchItem);

	NSInteger branchRow = [sidebar.sourceView rowForItem:branchItem];
	XCTAssertGreaterThanOrEqual(branchRow, (NSInteger)0);
	NSMenu *branchMenu = [sidebar menuForRow:branchRow];
	XCTAssertFalse(branchMenu.autoenablesItems);

	PBWindowSubmodule *submodule = [PBWindowSubmodule new];
	submodule.name = @"CharacterizedSubmodule";
	submodule.path = @"CharacterizedSubmodule";
	submodule.parentRepository = self.repository.gtRepo;
	PBSourceViewGitSubmoduleItem *submoduleItem = [PBSourceViewGitSubmoduleItem itemWithSubmodule:(GTSubmodule *)submodule];
	PBWindowOutlineView *outline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
	outline.testItem = submoduleItem;
	PBGitSidebarController *isolatedSidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																				 superController:self.controller];
	[isolatedSidebar setValue:outline forKey:@"sourceView"];
	[isolatedSidebar setValue:sidebar.remotes forKey:@"remotes"];
	NSMenu *submoduleMenu = [isolatedSidebar menuForRow:0];
	XCTAssertEqual(submoduleMenu.numberOfItems, (NSInteger)1);
	XCTAssertEqualObjects(submoduleMenu.itemArray.firstObject.title, @"Open Submodule");
	XCTAssertEqual(submoduleMenu.itemArray.firstObject.target, isolatedSidebar);
	XCTAssertEqualObjects(submoduleMenu.itemArray.firstObject.representedObject, submoduleItem.path);
	XCTAssertFalse([isolatedSidebar outlineView:outline shouldEditTableColumn:nil item:submoduleItem]);

	XCTestExpectation *sortNotification = [self expectationForNotification:@"PBBranchSidebarSettingsDidChangeNotification"
																	object:nil
																   handler:nil];
	[sidebar toggleBranchSort:self];
	[self waitForExpectations:@[ sortNotification ] timeout:1.0];
	[sidebar toggleBranchSort:self];

	[sidebar removeRevSpec:branchRevision];
	XCTAssertNil([sidebar itemForRev:branchRevision]);
	[sidebar removeRevSpec:branchRevision];
	[sidebar closeView];
}

- (void)testSidebarRoutesRemoteActionsAndBranchDoubleClicks
{
	PBWindowOutlineView *outline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	PBSourceViewItem *remotes = [PBSourceViewItem groupItemWithTitle:@"Remotes"];
	[sidebar setValue:outline forKey:@"sourceView"];
	[sidebar setValue:remotes forKey:@"remotes"];
	self.controller.interceptRemoteRouting = YES;

	NSSegmentedControl *sender = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)];
	sender.segmentCount = 4;
	PBSourceViewItem *branchItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:self.branchRef]];
	outline.testItem = branchItem;

	sender.selectedSegment = 1;
	[sidebar fetchPullPushAction:sender];
	sender.selectedSegment = 2;
	[sidebar fetchPullPushAction:sender];
	sender.selectedSegment = 3;
	[sidebar fetchPullPushAction:sender];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.pullRouteCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)1);
	XCTAssertEqualObjects(self.controller.lastBranch.ref, self.branchRef.ref);
	XCTAssertEqualObjects(self.controller.lastRemote.ref, self.remoteBranchRef.ref);

	sender.selectedSegment = -1;
	[sidebar fetchPullPushAction:sender];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.pullRouteCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)1);

	PBSourceViewItem *remoteBranchItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:self.remoteBranchRef]];
	outline.testItem = remoteBranchItem;
	sender.selectedSegment = 3;
	[sidebar fetchPullPushAction:sender];
	XCTAssertEqual(self.controller.pushRouteCount, (NSUInteger)2);
	XCTAssertNil(self.controller.lastBranch);

	PBSourceViewItem *configuredRemoteItem = [PBSourceViewItem itemWithTitle:@"origin"];
	configuredRemoteItem.parent = remotes;
	outline.testItem = configuredRemoteItem;
	sender.selectedSegment = 1;
	[sidebar fetchPullPushAction:sender];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)2);

	outline.testItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:self.tagRef]];
	[sidebar fetchPullPushAction:sender];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)2);

	self.repository.trackingRef = nil;
	outline.testItem = branchItem;
	[sidebar fetchPullPushAction:sender];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)2);
	self.repository.trackingRef = self.remoteBranchRef;

	[self.repository.operations removeAllObjects];
	[sidebar doubleClicked:self];
	XCTAssertEqualObjects(self.repository.operations, (@[ @"checkout" ]));
	self.repository.failingOperation = @"checkout";
	[sidebar doubleClicked:self];
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)1);
	self.repository.failingOperation = nil;
}

- (void)testSidebarRealNibLifecycleOutlineDataCellsExpansionAndLifetime
{
	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	NSView *sidebarView = sidebar.view;
	NSOutlineView *outline = sidebar.sourceView;
	NSView *controlsView = sidebar.sourceListControlsView;
	NSPopUpButton *actionButton = [sidebar valueForKey:@"actionButton"];
	NSSegmentedControl *remoteControls = [sidebar valueForKey:@"remoteControls"];

	XCTAssertNotNil(sidebarView);
	XCTAssertTrue([outline isKindOfClass:PBSidebarList.class]);
	XCTAssertEqual(outline.delegate, sidebar);
	XCTAssertEqual(outline.dataSource, sidebar);
	XCTAssertEqual(outline.target, sidebar);
	XCTAssertEqual(outline.doubleAction, @selector(doubleClicked:));
	XCTAssertEqualObjects(outline.accessibilityIdentifier, @"RepositorySidebar");
	XCTAssertNotNil(outline.menu);
	XCTAssertNotNil(controlsView);
	XCTAssertNotNil(actionButton);
	XCTAssertEqual(actionButton.menu.delegate, sidebar);
	XCTAssertNotNil(remoteControls);
	XCTAssertEqual(remoteControls.segmentCount, (NSInteger)4);
	XCTAssertEqual(remoteControls.target, sidebar);
	XCTAssertEqual(remoteControls.action, @selector(fetchPullPushAction:));

	XCTAssertEqual([sidebar outlineView:outline numberOfChildrenOfItem:nil], (NSInteger)sidebar.items.count);
	PBSourceViewItem *project = [sidebar outlineView:outline child:0 ofItem:nil];
	PBSourceViewItem *branches = [sidebar outlineView:outline child:1 ofItem:nil];
	XCTAssertEqualObjects(project.title, self.repository.projectName.uppercaseString);
	XCTAssertEqualObjects(branches.title, @"BRANCHES");
	XCTAssertTrue([sidebar outlineView:outline isGroupItem:project]);
	XCTAssertTrue([sidebar outlineView:outline isGroupItem:branches]);
	XCTAssertFalse([sidebar outlineView:outline isGroupItem:NSObject.new]);
	XCTAssertFalse([sidebar outlineView:outline shouldSelectItem:project]);
	XCTAssertTrue([sidebar outlineView:outline shouldSelectItem:NSObject.new]);
	XCTAssertFalse([sidebar outlineView:outline shouldShowOutlineCellForItem:project]);
	XCTAssertTrue([sidebar outlineView:outline shouldShowOutlineCellForItem:branches]);
	XCTAssertTrue([sidebar outlineView:outline shouldShowOutlineCellForItem:NSObject.new]);
	XCTAssertTrue([sidebar outlineView:outline isItemExpandable:branches]);
	XCTAssertGreaterThanOrEqual([sidebar outlineView:outline numberOfChildrenOfItem:branches], (NSInteger)2);
	PBSourceViewItem *firstBranch = [sidebar outlineView:outline child:0 ofItem:branches];
	XCTAssertEqualObjects([sidebar outlineView:outline objectValueForTableColumn:outline.tableColumns.firstObject byItem:firstBranch], firstBranch.title);
	XCTAssertTrue([sidebar outlineView:outline shouldSelectItem:firstBranch]);

	NSTableCellView *branchHeader = (NSTableCellView *)[sidebar outlineView:outline
														 viewForTableColumn:outline.tableColumns.firstObject
																	   item:branches];
	XCTAssertEqualObjects(branchHeader.identifier, @"PBBranchesHeaderCellIdentifier");
	XCTAssertEqualObjects(branchHeader.textField.stringValue, @"BRANCHES");
	NSButton *sortButton = nil;
	for (NSView *subview in branchHeader.subviews) {
		if ([subview.identifier isEqualToString:@"BranchSortToggle"]) sortButton = (NSButton *)subview;
	}
	XCTAssertNotNil(sortButton);
	XCTAssertEqual(sortButton.target, sidebar);
	XCTAssertEqual(sortButton.action, @selector(toggleBranchSort:));
	XCTAssertNotNil(sortButton.image);
	XCTAssertGreaterThan(sortButton.toolTip.length, (NSUInteger)0);

	PBGitRevSpecifier *mainRevision = [[PBGitRevSpecifier alloc] initWithRef:self.branchRef];
	PBSourceViewItem *mainItem = [sidebar itemForRev:mainRevision];
	XCTAssertNotNil(mainItem);
	PBSidebarTableViewCell *mainCell = (PBSidebarTableViewCell *)[sidebar outlineView:outline
																   viewForTableColumn:outline.tableColumns.firstObject
																				 item:mainItem];
	XCTAssertTrue([mainCell isKindOfClass:PBSidebarTableViewCell.class]);
	XCTAssertEqualObjects(mainCell.textField.stringValue, mainItem.title);
	XCTAssertEqualObjects(mainCell.imageView.image, mainItem.icon);
	XCTAssertTrue(mainCell.isCheckedOut);
	PBGitRevSpecifier *tagRevision = [[PBGitRevSpecifier alloc] initWithRef:self.tagRef];
	PBSourceViewItem *tagItem = [sidebar itemForRev:tagRevision];
	PBSidebarTableViewCell *tagCell = (PBSidebarTableViewCell *)[sidebar outlineView:outline
																  viewForTableColumn:outline.tableColumns.firstObject
																				item:tagItem];
	XCTAssertFalse(tagCell.isCheckedOut);

	[sidebar expandCollapseItem:[NSNotification notificationWithName:NSOutlineViewItemWillCollapseNotification
															  object:outline
															userInfo:@{@"NSObject" : branches}]];
	XCTAssertFalse(branches.expanded);
	[sidebar expandCollapseItem:[NSNotification notificationWithName:NSOutlineViewItemWillExpandNotification
															  object:outline
															userInfo:@{@"NSObject" : branches}]];
	XCTAssertTrue(branches.expanded);
	[sidebar expandCollapseItem:[NSNotification notificationWithName:NSOutlineViewItemWillCollapseNotification
															  object:outline
															userInfo:@{@"NSObject" : @"not an item"}]];
	XCTAssertTrue(branches.expanded);

	PBWindowOutlineView *rowOutline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	rowOutline.testItem = mainItem;
	rowOutline.testItemRow = 0;
	rowOutline.testRowView = [NSTableRowView new];
	PBGitSidebarController *rowSidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository superController:self.controller];
	[rowSidebar setValue:rowOutline forKey:@"sourceView"];
	XCTAssertEqual([rowSidebar outlineView:rowOutline rowViewForItem:mainItem], rowOutline.testRowView);
	rowOutline.testRowView = nil;
	XCTAssertNotNil([rowSidebar outlineView:rowOutline rowViewForItem:mainItem]);
	[rowSidebar setValue:nil forKey:@"sourceView"];
	XCTAssertNotNil([rowSidebar outlineView:rowOutline rowViewForItem:mainItem]);

	[sidebar closeView];
	__weak PBGitSidebarController *weakSidebar = nil;
	@autoreleasepool {
		PBGitSidebarController *temporarySidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																					  superController:self.controller];
		(void)temporarySidebar.view;
		[temporarySidebar closeView];
		weakSidebar = temporarySidebar;
		temporarySidebar = nil;
	}
	XCTAssertNil(weakSidebar);
	[[NSNotificationCenter defaultCenter] postNotificationName:@"PBBranchSidebarSettingsDidChangeNotification" object:nil];
}

- (void)testSidebarPresentsGitHubCollaborationAndRoutesNativeSurfaces
{
	[self configureForgeRemotes:@{@"origin" : @"https://github.com/hbmartin/gitx.git"}];
	self.controller.interceptContentChange = YES;
	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	(void)sidebar.view;
	NSOutlineView *outline = sidebar.sourceView;
	[self pumpRunLoopFor:0.2];

	PBSourceViewItem *forgeGroup = [sidebar valueForKey:@"forgeGroup"];
	XCTAssertNotNil(forgeGroup);
	XCTAssertEqualObjects(forgeGroup.title, @"GITHUB");
	XCTAssertTrue([sidebar.items containsObject:forgeGroup]);
	XCTAssertEqual(forgeGroup.sortedChildren.count, (NSUInteger)1);
	PBSourceViewItem *repositoryItem = forgeGroup.sortedChildren.firstObject;
	XCTAssertTrue([repositoryItem.title containsString:@"hbmartin/gitx"]);
	XCTAssertTrue([repositoryItem.title containsString:@"Primary"]);
	XCTAssertNotNil(repositoryItem.icon);
	XCTAssertEqualObjects([repositoryItem.sortedChildren valueForKey:@"title"], (@[ @"Issues", @"Pull Requests" ]));
	XCTAssertEqualObjects([sidebar visibleChildrenForItem:forgeGroup], (@[ repositoryItem ]));
	NSArray<PBSourceViewItem *> *visibleSurfaces = [sidebar visibleChildrenForItem:repositoryItem];
	XCTAssertEqualObjects([visibleSurfaces valueForKey:@"title"], (@[ @"Pull Requests", @"Issues" ]));
	XCTAssertFalse([sidebar outlineView:outline shouldSelectItem:repositoryItem]);
	XCTAssertTrue([sidebar outlineView:outline shouldSelectItem:visibleSurfaces.firstObject]);

	for (PBSourceViewItem *surfaceItem in repositoryItem.sortedChildren) {
		XCTAssertNotNil(surfaceItem.icon);
		NSTableCellView *cell = (NSTableCellView *)[sidebar outlineView:outline
													 viewForTableColumn:outline.tableColumns.firstObject
																   item:surfaceItem];
		XCTAssertEqualObjects(cell.accessibilityIdentifier, @"RepositoryForgeSidebarItem");
		XCTAssertEqualObjects(cell.accessibilityLabel, surfaceItem.title);
	}

	PBSourceViewItem *pullRequests = [repositoryItem.sortedChildren filteredArrayUsingPredicate:
																		[NSPredicate predicateWithFormat:@"title == %@", @"Pull Requests"]]
										 .firstObject;
	NSInteger pullRequestsRow = [outline rowForItem:pullRequests];
	XCTAssertGreaterThanOrEqual(pullRequestsRow, (NSInteger)0);
	[outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)pullRequestsRow]
		 byExtendingSelection:NO];
	[sidebar outlineViewSelectionDidChange:
				 [NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification
											   object:outline]];
	XCTAssertGreaterThanOrEqual(self.controller.contentChangeCount, (NSUInteger)1);
	XCTAssertNotNil(self.controller.lastContentController);
	XCTAssertEqualObjects(self.controller.lastContentController.view.accessibilityIdentifier,
						  @"RepositoryForgeCollaboration");

	PBSourceViewItem *issues = [repositoryItem.sortedChildren filteredArrayUsingPredicate:
																  [NSPredicate predicateWithFormat:@"title == %@", @"Issues"]]
								   .firstObject;
	NSInteger issuesRow = [outline rowForItem:issues];
	XCTAssertGreaterThanOrEqual(issuesRow, (NSInteger)0);
	[outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)issuesRow]
		 byExtendingSelection:NO];
	[sidebar outlineViewSelectionDidChange:
				 [NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification
											   object:outline]];
	[sidebar reloadSidebarPresentation];
	XCTAssertEqualObjects([sidebar selectedItem].title, @"Issues");
	[sidebar forgeAccessDidChange:
				 [NSNotification notificationWithName:@"PBRepositoryForgeAccountDidChangeNotification"
											   object:self.repository]];
	XCTAssertEqualObjects([sidebar selectedItem].title, @"Issues");
	NSUInteger routedSurfaceCount = self.controller.contentChangeCount;
	[sidebar showForgeAttention:self];
	XCTAssertGreaterThan(self.controller.contentChangeCount, routedSurfaceCount);
	[sidebar attentionUnseenDidChange:
				 [NSNotification notificationWithName:@"PBRepositoryAttentionUnseenDidChangeNotification"
											   object:self.repository
											 userInfo:@{@"count" : @7}]];
	[sidebar closeView];
}

- (void)testSidebarRequiresAndPersistsAnExplicitPrimaryGitHubRepository
{
	[self configureForgeRemotes:@{
		@"origin" : @"https://github.com/hbmartin/gitx.git",
		@"upstream" : @"git@github.com:gitx/gitx.git",
	}];
	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	(void)sidebar.view;
	NSOutlineView *outline = sidebar.sourceView;
	PBSourceViewItem *forgeGroup = [sidebar valueForKey:@"forgeGroup"];
	PBSourceViewItem *choice = forgeGroup.sortedChildren.firstObject;
	XCTAssertEqualObjects(choice.title, @"Choose Primary Repository…");
	XCTAssertNotNil(choice.icon);
	XCTAssertTrue([sidebar outlineView:outline shouldSelectItem:choice]);
	NSInteger row = [outline rowForItem:choice];
	XCTAssertGreaterThanOrEqual(row, (NSInteger)0);
	PBWindowAlertResponse = NSAlertSecondButtonReturn;
	[outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
		 byExtendingSelection:NO];

	[sidebar outlineViewSelectionDidChange:
				 [NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification
											   object:outline]];
	XCTAssertEqualObjects([[sidebar valueForKey:@"forgeGroup"] sortedChildren].firstObject.title,
						  @"Choose Primary Repository…");

	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Choose Primary Repository"])
			[(NSPopUpButton *)alert.accessoryView selectItemWithTitle:@"GitHub — gitx/gitx (upstream)"];
	};
	[sidebar outlineViewSelectionDidChange:
				 [NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification
											   object:outline]];

	PBSourceViewItem *selectedForgeGroup = [sidebar valueForKey:@"forgeGroup"];
	XCTAssertEqual(selectedForgeGroup.sortedChildren.count, (NSUInteger)2);
	XCTAssertTrue([selectedForgeGroup.sortedChildren.firstObject.title containsString:@"gitx/gitx"]);
	XCTAssertFalse([selectedForgeGroup.sortedChildren.firstObject.title containsString:@"Choose Primary"]);
	[sidebar closeView];

	PBGitSidebarController *reloadedSidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																				 superController:self.controller];
	(void)reloadedSidebar.view;
	PBSourceViewItem *reloadedForgeGroup = [reloadedSidebar valueForKey:@"forgeGroup"];
	XCTAssertEqual(reloadedForgeGroup.sortedChildren.count, (NSUInteger)2);
	XCTAssertTrue([reloadedForgeGroup.sortedChildren.firstObject.title containsString:@"gitx/gitx"]);
	XCTAssertFalse([reloadedForgeGroup.sortedChildren.firstObject.title containsString:@"Choose Primary"]);
	[reloadedSidebar closeView];
}

- (void)testSidebarRefreshFollowsHeadPreservesExplicitSelectionAndHonorsVisibility
{
	NSUInteger reloadCount = self.repository.reloadRefsCount;
	self.repository.currentBranch = nil;
	PBGitSidebarController *unloadedSidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																				 superController:self.controller];
	[unloadedSidebar selectCurrentBranch];
	XCTAssertGreaterThan(self.repository.reloadRefsCount, reloadCount);
	XCTAssertEqualObjects(self.repository.currentBranch.simpleRef, @"refs/heads/main");

	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	(void)sidebar.view;
	PBRepositoryUISettings *settings = [[PBRepositoryUISettings alloc] initWithRepository:self.repository];
	[sidebar setValue:nil forKey:@"branchPresentation"];
	[sidebar reloadSidebarPresentation];
	XCTAssertNotNil([sidebar valueForKey:@"branchPresentation"]);
	PBGitRevSpecifier *mainRevision = [[PBGitRevSpecifier alloc] initWithRef:self.branchRef];
	PBGitRevSpecifier *featureRevision = [[PBGitRevSpecifier alloc] initWithRef:[self.repository refForName:@"feature"]];
	PBGitRevSpecifier *tagRevision = [[PBGitRevSpecifier alloc] initWithRef:self.tagRef];
	[sidebar setValue:nil forKey:@"branchPresentation"];
	PBGitRevSpecifier *fallbackRevision = [[PBGitRevSpecifier alloc]
		initWithRef:[PBGitRef refFromString:@"refs/heads/coverage-fallback"]];
	XCTAssertNotNil([sidebar addRevSpec:fallbackRevision]);
	PBSourceViewItem *branches = [sidebar valueForKey:@"branches"];
	XCTAssertGreaterThan([sidebar visibleChildrenForItem:branches].count, (NSUInteger)0);
	[sidebar reloadSidebarPresentation];
	branches = [sidebar valueForKey:@"branches"];
	NSInteger previousBranchSort = PBApplicationSettings.branchSort;
	@try {
		PBApplicationSettings.branchSort = 1;
		PBSourceViewItem *zuluWithoutReference = [PBSourceViewItem itemWithTitle:@"Zulu without reference"];
		PBSourceViewItem *alphaWithoutReference = [PBSourceViewItem itemWithTitle:@"Alpha without reference"];
		[branches addChild:zuluWithoutReference];
		[branches addChild:alphaWithoutReference];
		NSArray<PBSourceViewItem *> *recentItems = [sidebar visibleChildrenForItem:branches];
		XCTAssertLessThan([recentItems indexOfObject:alphaWithoutReference], [recentItems indexOfObject:zuluWithoutReference]);
	} @finally {
		PBApplicationSettings.branchSort = previousBranchSort;
	}

	NSArray<NSString *> *initialRemoteNames = [sidebar.remotes.sortedChildren valueForKey:@"title"];
	XCTAssertTrue([initialRemoteNames containsObject:@"origin"]);
	XCTAssertTrue([initialRemoteNames containsObject:@"backup"]);
	self.repository.testRemotes = @[ @"origin" ];
	[sidebar reloadSidebarAfterReferencesChange];
	NSArray<NSString *> *updatedRemoteNames = [sidebar.remotes.sortedChildren valueForKey:@"title"];
	XCTAssertTrue([updatedRemoteNames containsObject:@"origin"]);
	XCTAssertFalse([updatedRemoteNames containsObject:@"backup"]);
	[sidebar.remotes addChild:[PBSourceViewGitRemoteItem remoteItemWithTitle:@"stale"]];
	[sidebar synchronizeConfiguredRemotes];
	XCTAssertFalse([[sidebar.remotes.sortedChildren valueForKey:@"title"] containsObject:@"stale"]);

	settings.hideContainedBranches = YES;
	[sidebar reloadSidebarPresentation];
	XCTAssertNotNil([sidebar itemForRev:mainRevision]);
	XCTAssertNil([sidebar itemForRev:featureRevision]);
	settings.hideContainedBranches = NO;

	settings.sidebarVisibility = @{
		@"Remotes" : @NO,
		@"Tags" : @NO,
		@"Stashes" : @NO,
		@"Submodules" : @NO,
		@"Other" : @NO,
	};
	[sidebar repositorySettingsDidChange:[NSNotification notificationWithName:@"PBRepositorySettingsDidChangeNotification"
																	   object:self.repository]];
	XCTAssertEqual(sidebar.items.count, (NSUInteger)2);
	XCTAssertEqualObjects([sidebar.items valueForKey:@"title"], (@[ self.repository.projectName.uppercaseString, @"BRANCHES" ]));
	XCTAssertFalse([sidebar.items containsObject:sidebar.remotes]);
	settings.sidebarVisibility = @{
		@"Remotes" : @YES,
		@"Tags" : @YES,
		@"Stashes" : @YES,
		@"Submodules" : @YES,
		@"Other" : @YES,
	};
	[sidebar reloadSidebarPresentation];
	XCTAssertTrue([sidebar.items containsObject:sidebar.remotes]);

	self.repository.hidesProjectName = YES;
	self.repository.testRemotes = nil;
	PBGitSidebarController *nullableMetadataSidebar = [[PBGitSidebarController alloc]
		initWithRepository:self.repository
		   superController:self.controller];
	(void)nullableMetadataSidebar.view;
	XCTAssertEqualObjects([nullableMetadataSidebar.items.firstObject title], @"");
	XCTAssertEqualObjects([nullableMetadataSidebar.remotes.sortedChildren valueForKey:@"title"], (@[ @"origin" ]));
	[nullableMetadataSidebar closeView];
	self.repository.hidesProjectName = NO;
	self.repository.testRemotes = @[ @"origin", @"backup" ];

	self.repository.currentBranch = mainRevision;
	[self git:@[ @"checkout", @"--quiet", @"feature" ] directory:self.repositoryURL];
	[self.repository reloadRefs];
	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"refs/heads/feature");
	[sidebar reloadSidebarAfterReferencesChange];
	XCTAssertEqualObjects(self.repository.currentBranch.simpleRef, @"refs/heads/feature");
	XCTAssertEqualObjects([[sidebar selectedItem] revSpecifier].simpleRef, @"refs/heads/feature");

	self.repository.currentBranch = tagRevision;
	[self git:@[ @"checkout", @"--quiet", @"main" ] directory:self.repositoryURL];
	[self.repository reloadRefs];
	XCTAssertEqualObjects(self.repository.headRef.simpleRef, @"refs/heads/main");
	[sidebar reloadSidebarAfterReferencesChange];
	XCTAssertEqualObjects(self.repository.currentBranch.simpleRef, tagRevision.simpleRef);
	[sidebar reloadSidebarPresentation];
	XCTAssertEqualObjects([[sidebar selectedItem] revSpecifier], tagRevision);

	PBGitSidebarController *hiddenRowSidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																				  superController:self.controller];
	PBWindowOutlineView *hiddenRowOutline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	hiddenRowOutline.testItemRow = -1;
	[hiddenRowSidebar setValue:hiddenRowOutline forKey:@"sourceView"];
	[hiddenRowSidebar.items addObject:[PBSourceViewItem itemWithRevSpec:tagRevision]];
	[hiddenRowSidebar selectCurrentBranch];
	XCTAssertEqual(hiddenRowOutline.deselectAllCount, (NSUInteger)0,
				   @"A temporarily hidden current item must preserve the prior outline selection");
	XCTAssertEqual(hiddenRowOutline.selectRowsCount, (NSUInteger)0);

	self.repository.currentBranch = mainRevision;
	XCTestExpectation *backgroundObservation = [self expectationWithDescription:@"Background repository observation reaches the main actor"];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		self.repository.currentBranch = tagRevision;
		[backgroundObservation fulfill];
	});
	[self waitForExpectations:@[ backgroundObservation ] timeout:1.0];
	NSDate *selectionDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
	while (![[[sidebar selectedItem] revSpecifier] isEqual:tagRevision] && selectionDeadline.timeIntervalSinceNow > 0)
		[self pumpRunLoopFor:0.01];
	XCTAssertEqualObjects([[sidebar selectedItem] revSpecifier], tagRevision);

	[hiddenRowSidebar closeView];
	[sidebar closeView];
}

- (void)testSidebarSelectionMenusAndRemoteControlBoundaries
{
	PBWindowOutlineView *outline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	PBSourceViewItem *remotes = [PBSourceViewItem groupItemWithTitle:@"Remotes"];
	NSPopUpButton *actionButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 40, 24) pullsDown:YES];
	NSSegmentedControl *remoteControls = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)];
	remoteControls.segmentCount = 4;
	[sidebar setValue:outline forKey:@"sourceView"];
	[sidebar setValue:remotes forKey:@"remotes"];
	[sidebar setValue:actionButton forKey:@"actionButton"];
	[sidebar setValue:remoteControls forKey:@"remoteControls"];

	PBWindowHistoryMenuSpy *history = [[PBWindowHistoryMenuSpy alloc] initWithRepository:self.repository superController:self.controller];
	NSMenuItem *characterizedItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Characterized Reference Action", nil)
															   action:nil
														keyEquivalent:@""];
	history.testMenuItems = @[ characterizedItem ];
	[self.controller setValue:history forKey:@"_historyViewController"];
	self.controller.interceptContentChange = YES;
	self.controller.interceptRemoteRouting = YES;

	PBGitRef *featureRef = [self.repository refForName:@"feature"];
	PBSourceViewItem *branchItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:featureRef]];
	outline.testItem = branchItem;
	[sidebar outlineViewSelectionDidChange:[NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification object:outline]];
	XCTAssertEqualObjects(self.repository.currentBranch.simpleRef, @"refs/heads/feature");
	XCTAssertEqual(self.controller.contentChangeCount, (NSUInteger)1);
	XCTAssertEqual(self.controller.lastContentController, history);
	XCTAssertTrue(actionButton.enabled);
	XCTAssertTrue([remoteControls isEnabledForSegment:1]);
	XCTAssertTrue([remoteControls isEnabledForSegment:2]);
	XCTAssertTrue([remoteControls isEnabledForSegment:3]);

	[sidebar menuNeedsUpdate:actionButton.menu];
	XCTAssertEqual(actionButton.menu.numberOfItems, (NSInteger)2);
	XCTAssertNotNil(actionButton.menu.itemArray.firstObject.image);
	XCTAssertEqualObjects(actionButton.menu.itemArray.lastObject.title, characterizedItem.title);
	NSMenu *externalMenu = [NSMenu new];
	[sidebar menuNeedsUpdate:externalMenu];
	XCTAssertEqual(externalMenu.numberOfItems, (NSInteger)1);
	XCTAssertEqualObjects(externalMenu.itemArray.firstObject.title, characterizedItem.title);
	NSMenu *rowMenu = [sidebar menuForRow:0];
	XCTAssertFalse(rowMenu.autoenablesItems);
	XCTAssertEqual(rowMenu.numberOfItems, (NSInteger)1);

	outline.testItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:self.tagRef]];
	[sidebar outlineViewSelectionDidChange:[NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification object:outline]];
	XCTAssertTrue(actionButton.enabled);
	XCTAssertFalse([remoteControls isEnabledForSegment:1]);
	XCTAssertFalse([remoteControls isEnabledForSegment:2]);
	XCTAssertFalse([remoteControls isEnabledForSegment:3]);
	XCTAssertEqual(self.controller.contentChangeCount, (NSUInteger)2);

	outline.testItem = remotes;
	[sidebar outlineViewSelectionDidChange:[NSNotification notificationWithName:NSOutlineViewSelectionDidChangeNotification object:outline]];
	XCTAssertFalse(actionButton.enabled);
	XCTAssertFalse([remoteControls isEnabledForSegment:1]);
	XCTAssertEqual(self.controller.contentChangeCount, (NSUInteger)2);
	NSMenu *emptyMenu = [sidebar menuForRow:-1];
	XCTAssertEqual(emptyMenu.numberOfItems, (NSInteger)0);

	NSMenu *nilBoundaryMenu = [NSMenu new];
	[sidebar addMenuItemsForRef:nil toMenu:nilBoundaryMenu];
	[sidebar addMenuItemsForSubmodule:nil toMenu:nilBoundaryMenu];
	XCTAssertEqual(nilBoundaryMenu.numberOfItems, (NSInteger)0);

	PBWindowAddRemoteResponder *responder = [PBWindowAddRemoteResponder new];
	sidebar.nextResponder = responder;
	remoteControls.selectedSegment = 0;
	[sidebar fetchPullPushAction:remoteControls];
	XCTAssertEqual(responder.addRemoteCount, (NSUInteger)1);
	[sidebar fetchPullPushAction:nil];
	XCTAssertEqual(responder.addRemoteCount, (NSUInteger)2);
	remoteControls.selectedSegment = 1;
	[sidebar fetchPullPushAction:remoteControls];
	XCTAssertEqual(self.controller.fetchRouteCount, (NSUInteger)0);
}

- (void)testSidebarSubmoduleMenusOpeningErrorsAndDoubleClickBoundaries
{
	NSURL *submoduleURL = [self.repositoryURL URLByAppendingPathComponent:@"CharacterizedSubmodule" isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:submoduleURL withIntermediateDirectories:YES attributes:nil error:NULL];
	[self git:@[ @"init", @"--quiet", @"--initial-branch=main" ] directory:submoduleURL];
	PBWindowSubmodule *submodule = [PBWindowSubmodule new];
	submodule.name = @"CharacterizedSubmodule";
	submodule.path = @"CharacterizedSubmodule";
	submodule.parentRepository = self.repository.gtRepo;
	self.repository.submodules = [NSMutableArray arrayWithObject:(GTSubmodule *)submodule];

	PBGitSidebarController *sidebar = [[PBGitSidebarController alloc] initWithRepository:self.repository
																		 superController:self.controller];
	(void)sidebar.view;
	PBSourceViewItem *submodules = [sidebar valueForKey:@"submodules"];
	XCTAssertTrue([sidebar.items containsObject:submodules]);
	XCTAssertEqual(submodules.sortedChildren.count, (NSUInteger)1);
	PBSourceViewGitSubmoduleItem *submoduleItem = (PBSourceViewGitSubmoduleItem *)submodules.sortedChildren.firstObject;
	XCTAssertEqualObjects(submoduleItem.title, @"CharacterizedSubmodule");
	XCTAssertEqualObjects(submoduleItem.path.URLByResolvingSymlinksInPath, submoduleURL.URLByResolvingSymlinksInPath);
	NSInteger row = [sidebar.sourceView rowForItem:submoduleItem];
	XCTAssertGreaterThanOrEqual(row, (NSInteger)0);
	NSMenu *menu = [sidebar menuForRow:row];
	XCTAssertEqual(menu.numberOfItems, (NSInteger)1);
	NSMenuItem *openItem = menu.itemArray.firstObject;
	XCTAssertEqual(openItem.target, sidebar);
	XCTAssertEqual(openItem.action, @selector(openSubmoduleFromMenuItem:));
	XCTAssertEqualObjects(openItem.representedObject, submoduleItem.path);

	[sidebar openSubmoduleFromMenuItem:openItem];
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)1);
	XCTAssertEqualObjects(PBWindowDocumentOpenedURLs.lastObject.URLByResolvingSymlinksInPath, submoduleURL.URLByResolvingSymlinksInPath);
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)0);
	PBWindowDocumentOpenErrorsByPath[PBWindowResolvedPath(submoduleURL)] = self.repository.testError;
	[sidebar openSubmoduleFromMenuItem:openItem];
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)2);
	XCTAssertEqualObjects(self.controller.shownErrors.lastObject, self.repository.testError);

	PBWindowOutlineView *outline = [[PBWindowOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	outline.testItem = submoduleItem;
	[sidebar setValue:outline forKey:@"sourceView"];
	PBWindowDocumentOpenErrorsByPath[PBWindowResolvedPath(submoduleURL)] = nil;
	[sidebar doubleClicked:self];
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)3);

	NSPopUpButton *actionButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 40, 24) pullsDown:YES];
	[sidebar setValue:actionButton forKey:@"actionButton"];
	[sidebar menuNeedsUpdate:actionButton.menu];
	XCTAssertEqual(actionButton.menu.numberOfItems, (NSInteger)2);
	XCTAssertEqualObjects(actionButton.menu.itemArray.lastObject.title, @"Open Submodule");

	NSUInteger operationCount = self.repository.operations.count;
	outline.testItem = [PBSourceViewItem itemWithRevSpec:[[PBGitRevSpecifier alloc] initWithRef:self.tagRef]];
	[sidebar doubleClicked:self];
	XCTAssertEqual(self.repository.operations.count, operationCount);
	NSURL *invalidURL = [self.repositoryURL URLByAppendingPathComponent:@"MissingSubmodule" isDirectory:YES];
	[sidebar openSubmoduleAtURL:invalidURL];
	XCTAssertGreaterThanOrEqual(self.controller.shownErrors.count, (NSUInteger)2);
	[sidebar closeView];
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
	[self.controller revealInFinder:item];
	XCTAssertEqual(self.controller.revealedURLs.count, (NSUInteger)2);
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
	[directController openURLs:nil];
	[directController revealURLsInFinder:nil];
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

- (void)testBareRepositoryDisablesAndSafelyIgnoresWorkingDirectoryActions
{
	PBWindowRepositoryWithoutGitURLs *bareRepository = [PBWindowRepositoryWithoutGitURLs new];
	PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] init];
	[document setValue:bareRepository forKey:@"_repository"];
	PBGitWindowController *controller = [[PBGitWindowController alloc] initWithWindow:self.controller.window];
	controller.document = document;
	NSMenuItem *reveal = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Reveal in Finder", nil) action:@selector(revealInFinder:) keyEquivalent:@""];
	NSMenuItem *terminal = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open in Terminal", nil) action:@selector(openInTerminal:) keyEquivalent:@""];
	NSUInteger previousRevealCount = PBWindowWorkspaceRevealCount;

	XCTAssertFalse([controller validateMenuItem:reveal]);
	XCTAssertFalse([controller validateMenuItem:terminal]);
	XCTAssertNoThrow([controller revealInFinder:self]);
	XCTAssertEqual(PBWindowWorkspaceRevealCount, previousRevealCount);
}

- (void)testRepositoryOpeningCanonicalizesNestedLinkedAndBareRepositoriesInInputOrder
{
	NSURL *nestedURL = [self.repositoryURL URLByAppendingPathComponent:@"Sources/Ünicode/Nested" isDirectory:YES];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:nestedURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);

	NSString *linkedName = [NSString stringWithFormat:@"GitXLinkedOpening-%@", NSUUID.UUID.UUIDString];
	NSURL *linkedURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:linkedName] isDirectory:YES];
	NSString *linkedBranch = [NSString stringWithFormat:@"linked-opening-%@", NSUUID.UUID.UUIDString];
	[self git:@[ @"worktree", @"add", @"--quiet", @"-b", linkedBranch, linkedURL.path, @"HEAD" ]
		directory:self.repositoryURL];

	@try {
		XCTestExpectation *completion = [self expectationWithDescription:@"repository opening completed"];
		__block NSArray<NSDocument *> *openedDocuments = nil;
		__block NSArray<NSError *> *openingErrors = nil;
		[[PBRepositoryOpenCoordinator shared] openURLs:@[ nestedURL, linkedURL, self.remoteURL ]
										  sourceWindow:nil
											completion:^(NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
												openedDocuments = documents;
												openingErrors = errors;
												[completion fulfill];
											}];
		[self waitForExpectations:@[ completion ] timeout:1.0];

		XCTAssertEqual(openedDocuments.count, (NSUInteger)0);
		XCTAssertEqual(openingErrors.count, (NSUInteger)0);
		XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)3);
		XCTAssertEqual(PBWindowDocumentOpenedURLs.count, (NSUInteger)3);
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[0]),
							  PBWindowResolvedPath(self.repositoryURL));
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[1]),
							  PBWindowResolvedPath(linkedURL));
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[2]),
							  PBWindowResolvedPath(self.remoteURL));
	} @finally {
		[self git:@[ @"worktree", @"remove", @"--force", linkedURL.path ] directory:self.repositoryURL];
		[NSFileManager.defaultManager removeItemAtURL:linkedURL error:NULL];
	}
}

- (void)testRepositoryOpeningContinuesAfterFailureAndCompletesEmptyInput
{
	NSError *expectedError = [NSError errorWithDomain:@"RepositoryOpeningCharacterization"
												 code:23
											 userInfo:@{NSLocalizedDescriptionKey : @"expected open failure"}];
	PBWindowDocumentOpenErrorsByPath[PBWindowResolvedPath(self.repositoryURL)] = expectedError;

	XCTestExpectation *batchCompletion = [self expectationWithDescription:@"repository batch completed"];
	__block NSUInteger batchCompletionCount = 0;
	__block NSArray<NSError *> *batchErrors = nil;
	[[PBRepositoryOpenCoordinator shared] openURLs:@[ self.repositoryURL, self.remoteURL ]
									  sourceWindow:nil
										completion:^(__unused NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
											batchCompletionCount++;
											batchErrors = errors;
											[batchCompletion fulfill];
										}];
	[self waitForExpectations:@[ batchCompletion ] timeout:1.0];

	XCTAssertEqual(batchCompletionCount, (NSUInteger)1);
	XCTAssertEqualObjects(batchErrors, @[ expectedError ]);
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)2);
	XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[0]),
						  PBWindowResolvedPath(self.repositoryURL));
	XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[1]),
						  PBWindowResolvedPath(self.remoteURL));

	[PBWindowDocumentOpenedURLs removeAllObjects];
	PBWindowDocumentOpenCount = 0;
	XCTestExpectation *emptyCompletion = [self expectationWithDescription:@"empty repository batch completed"];
	__block NSUInteger emptyCompletionCount = 0;
	[[PBRepositoryOpenCoordinator shared] openURLs:@[]
									  sourceWindow:nil
										completion:^(NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
											emptyCompletionCount++;
											XCTAssertEqual(documents.count, (NSUInteger)0);
											XCTAssertEqual(errors.count, (NSUInteger)0);
											[emptyCompletion fulfill];
										}];
	[self waitForExpectations:@[ emptyCompletion ] timeout:1.0];
	XCTAssertEqual(emptyCompletionCount, (NSUInteger)1);
	XCTAssertEqual(PBWindowDocumentOpenCount, (NSUInteger)0);
	XCTAssertEqual(PBWindowDocumentOpenedURLs.count, (NSUInteger)0);
}

- (void)testRepositoryDocumentOpensUnbornRepository
{
	NSString *name = [NSString stringWithFormat:@"GitXUnbornOpening-%@", NSUUID.UUID.UUIDString];
	NSURL *unbornURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:unbornURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	@try {
		[self git:@[ @"init", @"--quiet" ] directory:unbornURL];
		NSError *error = nil;
		PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] initWithContentsOfURL:unbornURL
																							ofType:PBGitRepositoryDocumentType
																							 error:&error];
		XCTAssertNotNil(document, @"%@", error);
		XCTAssertTrue(document.repository.gtRepo.isHEADUnborn);
		XCTAssertNil(document.repository.headOID);
		XCTAssertTrue([document.displayName containsString:@"unborn HEAD"]);
		[document close];
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:unbornURL error:NULL];
	}
}

- (void)testRepositoryDocumentNamesDetachedRepository
{
	NSString *name = [NSString stringWithFormat:@"GitXDetachedNaming-%@", NSUUID.UUID.UUIDString];
	NSURL *detachedURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:detachedURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	@try {
		[self git:@[ @"init", @"--quiet", @"--initial-branch=main" ] directory:detachedURL];
		[self git:@[ @"config", @"user.name", @"GitX Tests" ] directory:detachedURL];
		[self git:@[ @"config", @"user.email", @"gitx-tests@example.invalid" ] directory:detachedURL];
		[@"initial\n" writeToURL:[detachedURL URLByAppendingPathComponent:@"tracked.txt"]
					  atomically:YES
						encoding:NSUTF8StringEncoding
						   error:NULL];
		[self git:@[ @"add", @"--all" ] directory:detachedURL];
		[self git:@[ @"commit", @"--quiet", @"-m", @"initial" ] directory:detachedURL];
		[self git:@[ @"checkout", @"--detach", @"--quiet", @"HEAD" ] directory:detachedURL];

		NSError *error = nil;
		PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] initWithContentsOfURL:detachedURL
																							ofType:PBGitRepositoryDocumentType
																							 error:&error];
		XCTAssertNotNil(document, @"%@", error);
		XCTAssertTrue(document.repository.gtRepo.isHEADDetached);
		XCTAssertTrue([document.displayName containsString:@"detached HEAD"]);
		[document close];
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:detachedURL error:NULL];
	}
}

- (void)testRepositoryDeallocatesAfterIndexServicesCreated
{
	// Regression: PBIndexMutationService retained its repository strongly, forming the cycle
	// PBGitRepository -> PBGitIndex -> mutationService -> repository. That leaked the whole repository
	// (including its live FSEvents watcher) every time a document closed. The mutation service now holds
	// the repository `unowned`, matching every sibling repository service, so the graph must deallocate.
	NSString *name = [NSString stringWithFormat:@"GitXRetainCycle-%@", NSUUID.UUID.UUIDString];
	NSURL *repoURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:repoURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	__weak PBGitRepository *weakRepository = nil;
	__weak PBGitIndex *weakIndex = nil;
	@try {
		[self git:@[ @"init", @"--quiet" ] directory:repoURL];
		@autoreleasepool {
			NSError *error = nil;
			PBGitRepositoryDocument *document = [[PBGitRepositoryDocument alloc] initWithContentsOfURL:repoURL
																								ofType:PBGitRepositoryDocumentType
																								 error:&error];
			XCTAssertNotNil(document, @"%@", error);
			PBGitIndex *index = document.repository.index; // creates the mutation/commit services + coordinator
			XCTAssertNotNil(index);
			weakRepository = document.repository;
			weakIndex = index;
			[document close];
			document = nil;
			index = nil;
		}
		// Allow any deferred teardown (watcher invalidation, notification drain) to run.
		for (int i = 0; i < 20 && (weakRepository != nil || weakIndex != nil); i++)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		XCTAssertNil(weakRepository, @"PBGitRepository leaked after document close (retain cycle via index services)");
		XCTAssertNil(weakIndex, @"PBGitIndex leaked after document close");
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:repoURL error:NULL];
	}
}

- (void)testRepositoryDocumentRejectsPlainAndMalformedFoldersWithoutMutation
{
	NSString *name = [NSString stringWithFormat:@"GitXInvalidOpening-%@", NSUUID.UUID.UUIDString];
	NSURL *rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	NSURL *plainURL = [rootURL URLByAppendingPathComponent:@"Plain Folder" isDirectory:YES];
	NSURL *plainFileURL = [plainURL URLByAppendingPathComponent:@"existing-ü.txt"];
	NSURL *malformedURL = [rootURL URLByAppendingPathComponent:@"Malformed Folder" isDirectory:YES];
	NSURL *malformedGitURL = [malformedURL URLByAppendingPathComponent:@".git" isDirectory:YES];
	NSURL *metadataMarkerURL = [malformedGitURL URLByAppendingPathComponent:@"marker"];
	NSData *plainContents = [@"keep plain contents\n" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *metadataContents = [@"not repository metadata\n" dataUsingEncoding:NSUTF8StringEncoding];

	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:plainURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:malformedGitURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([plainContents writeToURL:plainFileURL options:NSDataWritingAtomic error:NULL]);
	XCTAssertTrue([metadataContents writeToURL:metadataMarkerURL options:NSDataWritingAtomic error:NULL]);

	@try {
		NSError *plainError = nil;
		PBGitRepositoryDocument *plainDocument = [[PBGitRepositoryDocument alloc] initWithContentsOfURL:plainURL
																								 ofType:PBGitRepositoryDocumentType
																								  error:&plainError];
		XCTAssertNil(plainDocument);
		XCTAssertNotNil(plainError);
		XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[plainURL URLByAppendingPathComponent:@".git"].path]);
		XCTAssertEqualObjects([NSData dataWithContentsOfURL:plainFileURL], plainContents);

		NSError *malformedError = nil;
		PBGitRepositoryDocument *malformedDocument = [[PBGitRepositoryDocument alloc] initWithContentsOfURL:malformedURL
																									 ofType:PBGitRepositoryDocumentType
																									  error:&malformedError];
		XCTAssertNil(malformedDocument);
		XCTAssertNotNil(malformedError);
		XCTAssertEqualObjects([NSData dataWithContentsOfURL:metadataMarkerURL], metadataContents);
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:rootURL error:NULL];
	}
}

- (void)testRepositoryOpeningOffersAndCreatesEmptyAndNonemptyFoldersInOrder
{
	NSString *name = [NSString stringWithFormat:@"GitXInitializableOpening-%@", NSUUID.UUID.UUIDString];
	NSURL *rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	NSURL *emptyURL = [rootURL URLByAppendingPathComponent:@"Empty Folder" isDirectory:YES];
	NSURL *nonemptyURL = [rootURL URLByAppendingPathComponent:@"Nonempty Ünicode" isDirectory:YES];
	NSURL *existingFileURL = [nonemptyURL URLByAppendingPathComponent:@"keep.txt"];
	NSData *existingContents = [@"keep existing contents\n" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:emptyURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:nonemptyURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([existingContents writeToURL:existingFileURL options:NSDataWritingAtomic error:NULL]);

	@try {
		PBWindowAlertResponse = NSAlertFirstButtonReturn;
		XCTestExpectation *completion = [self expectationWithDescription:@"initializable folders opened"];
		__block NSArray<NSError *> *openingErrors = nil;
		[[PBRepositoryOpenCoordinator shared] openURLs:@[ emptyURL, nonemptyURL ]
										  sourceWindow:self.controller.window
											completion:^(__unused NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
												openingErrors = errors;
												[completion fulfill];
											}];
		[self waitForExpectations:@[ completion ] timeout:2.0];

		XCTAssertEqual(openingErrors.count, (NSUInteger)0);
		XCTAssertEqual(PBWindowAlertSheetCount, (NSUInteger)2);
		XCTAssertEqual(PBWindowAlertAppModalCount, (NSUInteger)0);
		XCTAssertEqual(PBWindowPresentedAlerts.count, (NSUInteger)2);
		for (NSAlert *alert in PBWindowPresentedAlerts) {
			XCTAssertEqualObjects(alert.buttons.firstObject.title, @"Create Repository");
			XCTAssertEqualObjects(alert.buttons.lastObject.title, @"Cancel");
		}
		[self attachScreenshotOfView:PBWindowPresentedAlerts.firstObject.window.contentView
								name:@"Repository creation prompt"];
		XCTAssertEqual(PBWindowDocumentOpenedURLs.count, (NSUInteger)2);
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[0]), PBWindowResolvedPath(emptyURL));
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs[1]), PBWindowResolvedPath(nonemptyURL));
		XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[emptyURL URLByAppendingPathComponent:@".git"].path]);
		XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[nonemptyURL URLByAppendingPathComponent:@".git"].path]);
		XCTAssertEqualObjects([NSData dataWithContentsOfURL:existingFileURL], existingContents);

		NSError *emptyError = nil;
		GTRepository *emptyRepository = [GTRepository repositoryWithURL:emptyURL error:&emptyError];
		XCTAssertNotNil(emptyRepository, @"%@", emptyError);
		XCTAssertTrue(emptyRepository.isHEADUnborn);
		NSError *nonemptyError = nil;
		GTRepository *nonemptyRepository = [GTRepository repositoryWithURL:nonemptyURL error:&nonemptyError];
		XCTAssertNotNil(nonemptyRepository, @"%@", nonemptyError);
		XCTAssertTrue(nonemptyRepository.isHEADUnborn);
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:rootURL error:NULL];
	}
}

- (void)testRepositoryOpeningCancelIsAppModalLeavesFolderUntouchedAndContinues
{
	NSString *name = [NSString stringWithFormat:@"GitXCancelledOpening-%@", NSUUID.UUID.UUIDString];
	NSURL *plainURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	NSURL *existingFileURL = [plainURL URLByAppendingPathComponent:@"keep.txt"];
	NSData *existingContents = [@"do not change\n" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:plainURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([existingContents writeToURL:existingFileURL options:NSDataWritingAtomic error:NULL]);

	@try {
		PBWindowAlertResponse = NSAlertSecondButtonReturn;
		XCTestExpectation *completion = [self expectationWithDescription:@"cancelled folder skipped"];
		__block NSArray<NSError *> *openingErrors = nil;
		[[PBRepositoryOpenCoordinator shared] openURLs:@[ plainURL, self.repositoryURL ]
										  sourceWindow:nil
											completion:^(__unused NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
												openingErrors = errors;
												[completion fulfill];
											}];
		[self waitForExpectations:@[ completion ] timeout:2.0];

		XCTAssertEqual(openingErrors.count, (NSUInteger)0);
		XCTAssertEqual(PBWindowAlertSheetCount, (NSUInteger)0);
		XCTAssertEqual(PBWindowAlertAppModalCount, (NSUInteger)1);
		XCTAssertEqual(PBWindowPresentedAlerts.count, (NSUInteger)1);
		XCTAssertEqualObjects(PBWindowPresentedAlerts.firstObject.buttons.firstObject.title, @"Create Repository");
		XCTAssertEqualObjects(PBWindowPresentedAlerts.firstObject.buttons.lastObject.title, @"Cancel");
		XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[plainURL URLByAppendingPathComponent:@".git"].path]);
		XCTAssertEqualObjects([NSData dataWithContentsOfURL:existingFileURL], existingContents);
		XCTAssertEqual(PBWindowDocumentOpenedURLs.count, (NSUInteger)1);
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs.firstObject),
							  PBWindowResolvedPath(self.repositoryURL));
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:plainURL error:NULL];
	}
}

- (void)testRepositoryOpeningRejectsMalformedMetadataAndInvalidInputsWithoutOfferingCreation
{
	NSString *name = [NSString stringWithFormat:@"GitXRejectedOpening-%@", NSUUID.UUID.UUIDString];
	NSURL *rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	NSURL *malformedDirectoryURL = [rootURL URLByAppendingPathComponent:@"Malformed Directory" isDirectory:YES];
	NSURL *malformedFileURL = [rootURL URLByAppendingPathComponent:@"Malformed File" isDirectory:YES];
	NSURL *regularFileURL = [rootURL URLByAppendingPathComponent:@"regular.txt"];
	NSURL *missingURL = [rootURL URLByAppendingPathComponent:@"Missing Folder" isDirectory:YES];
	NSURL *nonfileURL = [NSURL URLWithString:@"https://example.invalid/repository"];
	XCTAssertNotNil(nonfileURL);
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:[malformedDirectoryURL URLByAppendingPathComponent:@".git"]
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:malformedFileURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	XCTAssertTrue([@"invalid git metadata\n" writeToURL:[malformedFileURL URLByAppendingPathComponent:@".git"]
											 atomically:YES
											   encoding:NSUTF8StringEncoding
												  error:NULL]);
	XCTAssertTrue([@"not a folder\n" writeToURL:regularFileURL
									 atomically:YES
									   encoding:NSUTF8StringEncoding
										  error:NULL]);

	@try {
		XCTestExpectation *completion = [self expectationWithDescription:@"invalid inputs rejected"];
		__block NSArray<NSError *> *openingErrors = nil;
		[[PBRepositoryOpenCoordinator shared] openURLs:@[
			malformedDirectoryURL,
			malformedFileURL,
			regularFileURL,
			missingURL,
			nonfileURL,
			self.repositoryURL,
		]
										  sourceWindow:self.controller.window
											completion:^(__unused NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
												openingErrors = errors;
												[completion fulfill];
											}];
		[self waitForExpectations:@[ completion ] timeout:2.0];

		XCTAssertEqual(openingErrors.count, (NSUInteger)5);
		XCTAssertEqual(PBWindowPresentedAlerts.count, (NSUInteger)0);
		XCTAssertEqual(PBWindowDocumentOpenedURLs.count, (NSUInteger)1);
		XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs.firstObject),
							  PBWindowResolvedPath(self.repositoryURL));
		XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[malformedDirectoryURL URLByAppendingPathComponent:@".git"].path]);
		XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[malformedFileURL URLByAppendingPathComponent:@".git"].path]);
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:rootURL error:NULL];
	}
}

- (void)testRepositoryOpeningReportsInitializationFailureAndContinues
{
	NSString *name = [NSString stringWithFormat:@"GitXFailedInitialization-%@", NSUUID.UUID.UUIDString];
	NSURL *plainURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:plainURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertPresentationHook = ^(__unused NSAlert *alert) {
		[NSFileManager.defaultManager removeItemAtURL:plainURL error:NULL];
		[@"block repository initialization\n" writeToURL:plainURL
											  atomically:YES
												encoding:NSUTF8StringEncoding
												   error:NULL];
	};

	XCTestExpectation *completion = [self expectationWithDescription:@"initialization failure reported"];
	__block NSArray<NSError *> *openingErrors = nil;
	[[PBRepositoryOpenCoordinator shared] openURLs:@[ plainURL, self.repositoryURL ]
									  sourceWindow:self.controller.window
										completion:^(__unused NSArray<NSDocument *> *documents, NSArray<NSError *> *errors) {
											openingErrors = errors;
											[completion fulfill];
										}];
	[self waitForExpectations:@[ completion ] timeout:2.0];

	XCTAssertEqual(PBWindowAlertSheetCount, (NSUInteger)1);
	XCTAssertEqual(openingErrors.count, (NSUInteger)1);
	XCTAssertEqual(PBWindowDocumentOpenedURLs.count, (NSUInteger)1);
	XCTAssertEqualObjects(PBWindowResolvedPath(PBWindowDocumentOpenedURLs.firstObject),
						  PBWindowResolvedPath(self.repositoryURL));
	[NSFileManager.defaultManager removeItemAtURL:plainURL error:NULL];
}

- (void)testFolderDocumentTypeRegistersPublicFolderAsAlternateViewer
{
	NSArray<NSDictionary *> *documentTypes = NSBundle.mainBundle.infoDictionary[@"CFBundleDocumentTypes"];
	NSDictionary *folderType = nil;
	for (NSDictionary *documentType in documentTypes) {
		if ([documentType[@"LSItemContentTypes"] containsObject:@"public.folder"]) {
			folderType = documentType;
			break;
		}
	}

	XCTAssertNotNil(folderType);
	XCTAssertEqualObjects(folderType[@"CFBundleTypeRole"], @"Viewer");
	XCTAssertEqualObjects(folderType[@"LSHandlerRank"], @"Alternate");
}

- (void)testPreferencesWindowCharacterizesExistingToolbarAndSizing
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	id previousViewIdentifier = [defaults objectForKey:@"PBGitXPreferenceViewIdentifier"];
	[defaults setObject:@"General" forKey:@"PBGitXPreferenceViewIdentifier"];
	PBPrefsWindowController *preferences = nil;
	@try {
		preferences = [[PBPrefsWindowController alloc] initWithWindowNibName:@"Preferences"];
		[preferences showWindow:nil];
		NSArray<NSToolbarItemIdentifier> *identifiers = [preferences toolbarAllowedItemIdentifiers:preferences.window.toolbar];

		XCTAssertEqual(identifiers.count, (NSUInteger)9);
		XCTAssertEqualObjects(identifiers, (@[ @"General", @"Accounts", @"Dock Icon", @"Windows", @"Diff & Text", @"Terminal", @"Integration", @"History & Fetch", @"Updates" ]));
		XCTAssertFalse((preferences.window.styleMask & NSWindowStyleMaskResizable) != 0);
		XCTAssertEqual(preferences.window.toolbar.displayMode, NSToolbarDisplayModeIconAndLabel);
		XCTAssertFalse(preferences.window.toolbar.allowsUserCustomization);
		XCTAssertGreaterThanOrEqual(preferences.window.frame.size.width, 860.0);
		NSPopUpButton *appearancePopup = [preferences valueForKey:@"appearancePopup"];
		XCTAssertEqualObjects([appearancePopup.itemArray valueForKey:@"title"],
							  (@[ @"Automatic (System)", @"Light", @"Dark" ]));
		NSView *generalPrefsView = [preferences valueForKey:@"generalPrefsView"];
		NSMutableArray<NSView *> *pendingViews = [NSMutableArray arrayWithObject:preferences.window.contentView];
		BOOL foundCommitGuideControl = NO;
		NSButton *repositoryWatcherControl = nil;
		NSButton *repositoryStatusBarControl = nil;
		while (pendingViews.count > 0) {
			NSView *view = pendingViews.firstObject;
			[pendingViews removeObjectAtIndex:0];
			if ([view isKindOfClass:NSButton.class] &&
				[((NSButton *)view).title isEqualToString:@"Show column guides in commit message"]) {
				foundCommitGuideControl = YES;
			}
			if ([view isKindOfClass:NSButton.class] &&
				[((NSButton *)view).title isEqualToString:@"Watch for changes in repositories"]) {
				repositoryWatcherControl = (NSButton *)view;
			}
			if ([view isKindOfClass:NSButton.class] &&
				[((NSButton *)view).title isEqualToString:@"Show repository status bar"]) {
				repositoryStatusBarControl = (NSButton *)view;
			}
			[pendingViews addObjectsFromArray:view.subviews];
		}
		XCTAssertFalse(foundCommitGuideControl);
		XCTAssertNotNil(repositoryWatcherControl);
		XCTAssertTrue([repositoryWatcherControl isDescendantOf:preferences.window.contentView]);
		NSRect watcherFrame = [repositoryWatcherControl convertRect:repositoryWatcherControl.bounds
															 toView:preferences.window.contentView];
		XCTAssertTrue(NSIntersectsRect(preferences.window.contentView.bounds, watcherFrame));
		XCTAssertNotNil(repositoryStatusBarControl);
		NSRect statusBarFrame = [repositoryStatusBarControl convertRect:repositoryStatusBarControl.bounds
																 toView:preferences.window.contentView];
		XCTAssertTrue(NSIntersectsRect(preferences.window.contentView.bounds, statusBarFrame));
		XCTAssertEqual(generalPrefsView.frame.size.height, 258.0);
	} @finally {
		[preferences close];
		if (previousViewIdentifier)
			[defaults setObject:previousViewIdentifier forKey:@"PBGitXPreferenceViewIdentifier"];
		else
			[defaults removeObjectForKey:@"PBGitXPreferenceViewIdentifier"];
	}
}

- (void)testRepositoryToolbarInstallsSingleHistoryConfiguration
{
	PBRepositoryToolbarController *toolbarController = [[PBRepositoryToolbarController alloc] initWithWindowController:self.controller];
	[toolbarController install];
	NSToolbar *historyToolbar = self.controller.window.toolbar;

	XCTAssertEqualObjects(historyToolbar.identifier, @"GitX.Repository.HistoryToolbar");
	XCTAssertTrue(historyToolbar.allowsUserCustomization);
	XCTAssertTrue(historyToolbar.autosavesConfiguration);
	XCTAssertEqual(historyToolbar.displayMode, NSToolbarDisplayModeIconAndLabel);
	XCTAssertFalse([toolbarController respondsToSelector:NSSelectorFromString(@"setHistoryMode:")]);
	NSArray<NSToolbarItemIdentifier> *historyDefaults = [toolbarController toolbarDefaultItemIdentifiers:historyToolbar];
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Commit"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.ViewRemote"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.RefreshStatus"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Actions"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Reveal"]);
	XCTAssertTrue([historyDefaults containsObject:@"GitX.Toolbar.Terminal"]);
	NSArray<NSToolbarItemIdentifier> *historyAllowed = [toolbarController toolbarAllowedItemIdentifiers:historyToolbar];
	XCTAssertTrue([historyAllowed containsObject:@"GitX.Toolbar.Commit"]);
	XCTAssertTrue([historyAllowed containsObject:@"GitX.Toolbar.Pull"]);
	XCTAssertTrue([historyAllowed containsObject:@"GitX.Toolbar.Fetch"]);
	XCTAssertTrue([historyAllowed containsObject:@"GitX.Toolbar.CreateBranch"]);
	XCTAssertFalse([historyAllowed containsObject:@"GitX.Toolbar.History"]);

	NSToolbarItem *commitItem = [toolbarController toolbar:historyToolbar itemForItemIdentifier:@"GitX.Toolbar.Commit" willBeInsertedIntoToolbar:NO];
	XCTAssertNotNil(commitItem);
	XCTAssertEqualObjects(commitItem.label, @"Uncommitted Changes");
	XCTAssertEqual(commitItem.action, @selector(showUncommittedChanges:));
	XCTAssertEqual(commitItem.target, self.controller);
	NSToolbarItem *attentionItem = [toolbarController toolbar:historyToolbar
										itemForItemIdentifier:@"GitX.Toolbar.Attention"
									willBeInsertedIntoToolbar:YES];
	XCTAssertEqualObjects(attentionItem.label, @"Attention");
	NSTextField *attentionBadge = nil;
	NSButton *attentionButton = nil;
	for (NSView *view in attentionItem.view.subviews) {
		if ([view.accessibilityIdentifier isEqualToString:@"GitX.Toolbar.Attention.Badge"])
			attentionBadge = (NSTextField *)view;
		if ([view.accessibilityIdentifier isEqualToString:@"GitX.Toolbar.Attention"])
			attentionButton = (NSButton *)view;
	}
	XCTAssertNotNil(attentionBadge);
	XCTAssertNotNil(attentionButton);
	XCTAssertTrue(attentionBadge.hidden);
	[toolbarController attentionUnseenDidChange:
						   [NSNotification notificationWithName:@"PBRepositoryAttentionUnseenDidChangeNotification"
														 object:NSObject.new
													   userInfo:@{@"count" : @99}]];
	XCTAssertTrue(attentionBadge.hidden);
	[toolbarController attentionUnseenDidChange:
						   [NSNotification notificationWithName:@"PBRepositoryAttentionUnseenDidChangeNotification"
														 object:self.repository
													   userInfo:@{@"count" : @7}]];
	XCTAssertEqualObjects(attentionItem.label, @"Attention (7)");
	XCTAssertEqualObjects(attentionBadge.stringValue, @"7");
	XCTAssertFalse(attentionBadge.hidden);
	XCTAssertTrue([attentionButton.accessibilityLabel containsString:@"7 unseen"]);

	[toolbarController updateWithStatus:@"Loading commits" busy:YES baseWindowTitle:@"Repository"];
	XCTAssertEqualObjects(self.controller.window.title, @"Repository — Loading commits");

	[toolbarController install];
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
						  @"https://github.com/acme/repo/tree/feature%2Fsettings");
	XCTAssertEqualObjects([coordinator webURLForRemoteURL:@"deploy@example.com:team/repo.git" branch:@"main" sha:@"abc"].absoluteString,
						  @"https://example.com/team/repo/tree/main");
	XCTAssertEqualObjects([coordinator webURLForRemoteURL:@"ssh://git@gitlab.example/acme/repo.git" branch:@"main" sha:@"abc"].absoluteString,
						  @"https://gitlab.example/acme/repo/-/tree/main");
	XCTAssertEqualObjects([coordinator webURLForRemoteURL:@"https://bitbucket.org/acme/repo.git" branch:@"" sha:@"abc123"].absoluteString,
						  @"https://bitbucket.org/acme/repo/src/abc123");
}

- (void)testViewingRemoteUsesTheLegacyCoordinatorWithAnAutomaticForgeBinding
{
	[self git:@[ @"remote", @"set-url", @"origin", @"https://github.com/acme/widgets.git" ] directory:self.repositoryURL];

	[PBRepositoryRemoteURLCoordinator.shared viewRemoteForRepository:self.repository presentingWindow:nil];

	XCTAssertEqual(PBWindowWorkspaceOpenCount, (NSUInteger)1);
}

- (void)testSuccessfulPushURLUsesRepositorySettingsAndMatchingRemoteHost
{
	[self configureForgeRemotes:@{@"origin" : @"https://github.com/acme/widgets.git"}];
	PBRepositorySettingsStore *settings = [[PBRepositorySettingsStore alloc] initWithRepository:self.repository];
	NSError *error = nil;
	XCTAssertTrue([settings setBool:YES forKey:@"gitx.autoOpenPushedURL" error:&error], @"%@", error);
	XCTAssertTrue([settings setBool:YES forKey:@"gitx.requirePushedURLHostMatch" error:&error], @"%@", error);
	NSUInteger openCount = PBWindowWorkspaceOpenedURLs.count;

	[PBRepositoryRemoteURLCoordinator.shared
		handleSuccessfulPushOutput:@"remote: Open https://gitlab.example/acme/widgets/merge_requests/42 to review."
						repository:self.repository
							remote:self.remoteBranchRef
				  presentingWindow:nil];
	[self pumpRunLoopFor:0.05];
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, openCount);

	[PBRepositoryRemoteURLCoordinator.shared
		handleSuccessfulPushOutput:@"remote: Open https://github.com/acme/widgets/pull/42 to review."
						repository:self.repository
							remote:self.remoteBranchRef
				  presentingWindow:nil];
	[self pumpRunLoopFor:0.05];

	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, openCount + 1);
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/acme/widgets/pull/42");
}

- (void)testViewingRemoteHonorsRepositoryCustomURLTemplate
{
	[self configureForgeRemotes:@{@"origin" : @"https://github.com/acme/widgets.git"}];
	PBRepositorySettingsStore *settings = [[PBRepositorySettingsStore alloc] initWithRepository:self.repository];
	NSError *error = nil;
	XCTAssertTrue([settings setString:@"{remoteURL}/compare/{branch}"
							   forKey:@"gitx.webURLTemplate"
								error:&error],
				  @"%@", error);

	[PBRepositoryRemoteURLCoordinator.shared viewRemoteForRepository:self.repository presentingWindow:nil];

	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/acme/widgets/compare/main");
}

- (void)testForgeActionsOpenRepositoryCheckedOutRevisionSelectedCommitAndComparison
{
	[self configureForgeRemotes:@{@"origin" : @"https://github.com/hbmartin/gitx.git"}];

	[self.controller viewForgeRepository:self];
	[self.controller viewForgeCheckedOutRevision:self];
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs, (@[
							  [NSURL URLWithString:@"https://github.com/hbmartin/gitx"],
							  [NSURL URLWithString:@"https://github.com/hbmartin/gitx/tree/main"],
						  ]));

	NSString *detachedSHA = self.repository.headOID.SHA;
	[self git:@[ @"checkout", @"--quiet", @"--detach", detachedSHA ] directory:self.repositoryURL];
	[self.repository readCurrentBranch];
	[self.controller viewForgeCheckedOutRevision:self];
	NSString *detachedURL = [NSString stringWithFormat:@"https://github.com/hbmartin/gitx/commit/%@", detachedSHA];
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString, detachedURL);

	PBWindowCommitStub *head = [[PBWindowCommitStub alloc] initWithSHA:@"1111111111111111111111111111111111111111"];
	PBWindowCommitStub *base = [[PBWindowCommitStub alloc] initWithSHA:@"2222222222222222222222222222222222222222"];
	PBWindowHistorySpy *history = [[PBWindowHistorySpy alloc] initWithRepository:self.repository superController:self.controller];
	[self.controller setValue:history forKey:@"_historyViewController"];
	history.selectedCommits = @[ head ];
	[self.controller viewForgeSelectedCommit:self];
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/hbmartin/gitx/commit/1111111111111111111111111111111111111111");

	history.selectedCommits = @[ head, base ];
	[self.controller viewForgeSelectedComparison:self];
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/hbmartin/gitx/compare/2222222222222222222222222222222222222222...1111111111111111111111111111111111111111");

	NSUInteger openCount = PBWindowWorkspaceOpenedURLs.count;
	history.selectedCommits = @[];
	[self.controller viewForgeSelectedCommit:self];
	[self.controller viewForgeSelectedComparison:self];
	history.selectedCommits = @[ head, base, head ];
	[self.controller viewForgeSelectedCommit:self];
	[self.controller viewForgeSelectedComparison:self];
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, openCount);

	history.selectedCommits = @[ [[PBWindowCommitStub alloc] initWithSHA:@"not a commit"] ];
	[self.controller viewForgeSelectedCommit:self];
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)1);
	XCTAssertEqualObjects(self.controller.shownErrors.lastObject.domain, @"com.gitx.forge.scripting");
	XCTAssertEqual(self.controller.shownErrors.lastObject.code, (NSInteger)18003);
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, openCount);

	NSString *emptyName = [NSString stringWithFormat:@"GitXForgeUnborn-%@", NSUUID.UUID.UUIDString];
	NSURL *emptyURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:emptyName]
								 isDirectory:YES];
	XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:emptyURL
										 withIntermediateDirectories:YES
														  attributes:nil
															   error:NULL]);
	@try {
		[self git:@[ @"init", @"--quiet", @"--initial-branch=main" ] directory:emptyURL];
		NSError *emptyError = nil;
		PBWindowRepositorySpy *emptyRepository = [[PBWindowRepositorySpy alloc] initWithURL:emptyURL error:&emptyError];
		XCTAssertNotNil(emptyRepository, @"%@", emptyError);
		emptyRepository.testRemotes = @[];
		[emptyRepository readCurrentBranch];
		PBWindowControllerSpy *emptyController = [[PBWindowControllerSpy alloc] initWithRepository:emptyRepository];
		[emptyController viewForgeCheckedOutRevision:self];
		XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, openCount);
		[emptyController.window orderOut:nil];
		[emptyController.window close];
	} @finally {
		[NSFileManager.defaultManager removeItemAtURL:emptyURL error:NULL];
	}
}

- (void)testForgeBindingChooserSupportsNilWindowCancelWindowSelectionAndDurableRetry
{
	[self configureForgeRemotes:@{
		@"origin" : @"https://github.com/hbmartin/gitx.git",
		@"upstream" : @"git@github.com:gitx/gitx.git",
	}];

	NSWindow *window = self.controller.window;
	[self.controller setWindow:nil];
	PBWindowAlertResponse = NSAlertSecondButtonReturn;
	[self.controller viewForgeRepository:self];
	XCTAssertEqual(PBWindowAlertAppModalCount, (NSUInteger)1);
	XCTAssertEqual(PBWindowAlertSheetCount, (NSUInteger)0);
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, (NSUInteger)0);
	NSAlert *cancelAlert = PBWindowPresentedAlerts.lastObject;
	XCTAssertEqualObjects(cancelAlert.messageText, @"Choose Primary Repository");
	XCTAssertEqualObjects([cancelAlert.buttons valueForKey:@"title"], (@[ @"Use Repository", @"Cancel" ]));
	NSPopUpButton *cancelPopup = (NSPopUpButton *)cancelAlert.accessoryView;
	XCTAssertTrue([cancelPopup isKindOfClass:NSPopUpButton.class]);
	XCTAssertEqualObjects(cancelPopup.accessibilityIdentifier, @"GitX.ForgeLinks.RepositoryChoice");
	XCTAssertEqualObjects(cancelPopup.accessibilityLabel, @"Primary repository");
	XCTAssertEqual(cancelPopup.itemTitles.count, (NSUInteger)2);

	[self.controller setWindow:window];
	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if (![alert.messageText isEqualToString:@"Choose Primary Repository"]) return;
		NSPopUpButton *popup = (NSPopUpButton *)alert.accessoryView;
		[popup selectItemWithTitle:NSLocalizedString(@"GitHub — gitx/gitx (upstream)", nil)];
	};
	[self.controller viewForgeRepository:self];
	XCTAssertEqual(PBWindowAlertSheetCount, (NSUInteger)1);
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString, @"https://github.com/gitx/gitx");

	NSUInteger alertCount = PBWindowPresentedAlerts.count;
	PBWindowControllerSpy *reloadedController = [[PBWindowControllerSpy alloc] initWithRepository:self.repository];
	[reloadedController viewForgeRepository:self];
	XCTAssertEqual(PBWindowPresentedAlerts.count, alertCount);
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString, @"https://github.com/gitx/gitx");
	[reloadedController.window orderOut:nil];
	[reloadedController.window close];
}

- (void)testForgeNumberPromptAndDestinationChooserAcceptAndCancelEveryVisiblePath
{
	[self configureForgeRemotes:@{@"origin" : @"https://github.com/hbmartin/gitx.git"}];

	PBWindowAlertResponse = NSAlertSecondButtonReturn;
	[self.controller showForgePullRequestOrIssue:self];
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, (NSUInteger)0);
	NSAlert *numberAlert = PBWindowPresentedAlerts.lastObject;
	XCTAssertEqualObjects(numberAlert.messageText, @"Open Pull Request or Issue");
	XCTAssertEqualObjects([numberAlert.buttons valueForKey:@"title"], (@[ @"Continue", @"Cancel" ]));
	NSTextField *field = (NSTextField *)numberAlert.accessoryView;
	XCTAssertTrue([field isKindOfClass:NSTextField.class]);
	XCTAssertEqualObjects(field.placeholderString, @"#123");
	XCTAssertEqualObjects(field.accessibilityIdentifier, @"GitX.ForgeLinks.NumberedReference");
	XCTAssertEqualObjects(field.accessibilityLabel, @"Pull Request or Issue reference");

	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Open Pull Request or Issue"])
			[(NSTextField *)alert.accessoryView setStringValue:NSLocalizedString(@"#42", nil)];
		else if ([alert.messageText isEqualToString:@"Choose a Destination"])
			[(NSPopUpButton *)alert.accessoryView selectItemAtIndex:0];
	};
	[self.controller showForgePullRequestOrIssue:self];
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/hbmartin/gitx/pull/42");
	NSAlert *destinationAlert = PBWindowPresentedAlerts.lastObject;
	XCTAssertEqualObjects(destinationAlert.messageText, @"Choose a Destination");
	XCTAssertEqualObjects([destinationAlert.buttons valueForKey:@"title"], (@[ @"Open", @"Cancel" ]));
	NSPopUpButton *destinationPopup = (NSPopUpButton *)destinationAlert.accessoryView;
	XCTAssertEqualObjects(destinationPopup.itemTitles, (@[
							  @"hbmartin/gitx — Pull Request #42",
							  @"hbmartin/gitx — Issue #42",
						  ]));
	XCTAssertEqualObjects(destinationPopup.accessibilityIdentifier, @"GitX.ForgeLinks.DestinationChoice");
	XCTAssertEqualObjects(destinationPopup.accessibilityLabel, @"Pull Request or Issue destination");

	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Open Pull Request or Issue"])
			[(NSTextField *)alert.accessoryView setStringValue:NSLocalizedString(@"#42", nil)];
		else if ([alert.messageText isEqualToString:@"Choose a Destination"])
			[(NSPopUpButton *)alert.accessoryView selectItemAtIndex:1];
	};
	[self.controller showForgePullRequestOrIssue:self];
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/hbmartin/gitx/issues/42");

	NSUInteger openCount = PBWindowWorkspaceOpenedURLs.count;
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Open Pull Request or Issue"])
			[(NSTextField *)alert.accessoryView setStringValue:NSLocalizedString(@"#42", nil)];
		else if ([alert.messageText isEqualToString:@"Choose a Destination"])
			PBWindowAlertResponse = NSAlertSecondButtonReturn;
	};
	[self.controller showForgePullRequestOrIssue:self];
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, openCount);
}

- (void)testForgeNumberPromptChoosesAmbiguousBindingThenRetriesIntoDestinationChoice
{
	[self configureForgeRemotes:@{
		@"origin" : @"https://github.com/hbmartin/gitx.git",
		@"upstream" : @"git@github.com:gitx/gitx.git",
	}];
	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Open Pull Request or Issue"])
			[(NSTextField *)alert.accessoryView setStringValue:NSLocalizedString(@"#42", nil)];
		else if ([alert.messageText isEqualToString:@"Choose Primary Repository"])
			[(NSPopUpButton *)alert.accessoryView selectItemWithTitle:NSLocalizedString(@"GitHub — gitx/gitx (upstream)", nil)];
		else if ([alert.messageText isEqualToString:@"Choose a Destination"])
			[(NSPopUpButton *)alert.accessoryView selectItemAtIndex:1];
	};

	[self.controller showForgePullRequestOrIssue:self];

	XCTAssertEqualObjects([PBWindowPresentedAlerts valueForKey:@"messageText"], (@[
							  @"Open Pull Request or Issue",
							  @"Choose Primary Repository",
							  @"Choose a Destination",
						  ]));
	XCTAssertEqualObjects(PBWindowWorkspaceOpenedURLs.lastObject.absoluteString,
						  @"https://github.com/gitx/gitx/issues/42");
}

- (void)testForgeMalformedNumberAndUnavailableRepositorySurfaceDeterministicErrors
{
	self.repository.testRemotes = @[];
	PBWindowAlertResponse = NSAlertFirstButtonReturn;
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Open Pull Request or Issue"])
			[(NSTextField *)alert.accessoryView setStringValue:NSLocalizedString(@"#9", nil)];
	};
	[self.controller viewForgeRepository:self];
	XCTAssertEqual(self.controller.shownErrors.lastObject.code, (NSInteger)18001);
	[self.controller showForgePullRequestOrIssue:self];
	XCTAssertEqual(self.controller.shownErrors.count, (NSUInteger)2);
	XCTAssertEqual(self.controller.shownErrors.lastObject.code, (NSInteger)18001);

	[self configureForgeRemotes:@{@"origin" : @"https://github.com/hbmartin/gitx.git"}];
	PBWindowControllerSpy *malformedController = [[PBWindowControllerSpy alloc] initWithRepository:self.repository];
	PBWindowAlertPresentationHook = ^(NSAlert *alert) {
		if ([alert.messageText isEqualToString:@"Open Pull Request or Issue"])
			[(NSTextField *)alert.accessoryView setStringValue:NSLocalizedString(@"42", nil)];
	};
	[malformedController showForgePullRequestOrIssue:self];
	XCTAssertEqual(malformedController.shownErrors.count, (NSUInteger)1);
	XCTAssertEqualObjects(malformedController.shownErrors.lastObject.domain, @"com.gitx.forge.scripting");
	XCTAssertEqual(malformedController.shownErrors.lastObject.code, (NSInteger)18003);
	XCTAssertEqual(PBWindowWorkspaceOpenedURLs.count, (NSUInteger)0);
	[malformedController.window orderOut:nil];
	[malformedController.window close];
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

- (void)testFileViewResizePreservesMinimumRightPaneWidth
{
	GLFileView *fileView = [GLFileView new];
	NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
	NSView *leftView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 200)];
	NSView *rightView = [[NSView alloc] initWithFrame:NSMakeRect(221, 0, 79, 200)];
	leftView.wantsLayer = YES;
	leftView.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
	rightView.wantsLayer = YES;
	rightView.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
	[splitView addSubview:leftView];
	[splitView addSubview:rightView];

	[fileView splitView:splitView resizeSubviewsWithOldSize:NSMakeSize(500, 200)];

	XCTAssertEqualWithAccuracy(rightView.frame.size.width, 180, 0.01);
	XCTAssertEqualWithAccuracy(leftView.frame.size.width,
							   splitView.frame.size.width - splitView.dividerThickness - 180,
							   0.01);
	[self attachScreenshotOfView:splitView name:@"File view minimum right pane width"];
}

- (void)testWelcomeWindowSearchAndCloseActions
{
	PBWelcomeWindowController *welcome = PBWelcomeWindowController.shared;
	id originalRecents = [NSUserDefaults.standardUserDefaults objectForKey:@"PBRecentRepositories"];
	[[PBRecentRepositoryStore shared] record:self.repositoryURL];
	[welcome show];
	[welcome searchChanged:nil];
	NSArray<NSView *> *descendants = welcome.window.contentView.subviews;
	NSTableView *recentsTable = nil;
	NSTextField *welcomeTitle = nil;
	while (descendants.count > 0 && (!recentsTable || !welcomeTitle)) {
		NSView *view = descendants.firstObject;
		descendants = [descendants subarrayWithRange:NSMakeRange(1, descendants.count - 1)];
		if ([view isKindOfClass:NSTableView.class] &&
			[view.accessibilityIdentifier isEqualToString:@"WelcomeRecents"]) {
			recentsTable = (NSTableView *)view;
		} else if ([view isKindOfClass:NSTextField.class] &&
				   [view.accessibilityIdentifier isEqualToString:@"WelcomeTitle"]) {
			welcomeTitle = (NSTextField *)view;
		}
		descendants = [descendants arrayByAddingObjectsFromArray:view.subviews];
	}

	XCTAssertNotNil(recentsTable);
	XCTAssertNotNil(welcomeTitle);
	NSFont *preferredTitleFont = [NSFont preferredFontForTextStyle:NSFontTextStyleTitle1 options:@{}];
	XCTAssertEqualObjects(welcomeTitle.font.fontName, preferredTitleFont.fontName);
	XCTAssertEqualWithAccuracy(welcomeTitle.font.pointSize, preferredTitleFont.pointSize, 0.01);
	[self attachScreenshotOfView:welcome.window.contentView name:@"Welcome window title typography"];
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
	NSString *defaultsKey = @"PBRepositoryUISettings";
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	id originalSettings = [defaults objectForKey:defaultsKey];
	[defaults removeObjectForKey:defaultsKey];
	@try {
		PBRepositoryUISettings *settings = [[PBRepositoryUISettings alloc] initWithRepository:[PBWindowRepositoryWithoutGitURLs new]];

		XCTAssertNotNil(settings);
		XCTAssertFalse(settings.pushAfterCommit);

		NSString *absolutePath = @"/tmp/gitx-absolute-common-directory";
		PBWindowRepositoryWithoutGitURLs *absoluteRepository = [PBWindowRepositoryWithoutGitURLs new];
		absoluteRepository.testCommonGitDirectoryOutput = absolutePath;
		PBRepositoryUISettings *absoluteSettings = [[PBRepositoryUISettings alloc] initWithRepository:absoluteRepository];
		absoluteSettings.pushAfterCommit = YES;

		NSURL *workingDirectoryURL = [NSURL fileURLWithPath:@"/tmp/gitx-relative-working-directory" isDirectory:YES];
		PBWindowRepositoryWithoutGitURLs *relativeRepository = [PBWindowRepositoryWithoutGitURLs new];
		relativeRepository.testCommonGitDirectoryOutput = @".git";
		relativeRepository.testWorkingDirectoryURL = workingDirectoryURL;
		PBRepositoryUISettings *relativeSettings = [[PBRepositoryUISettings alloc] initWithRepository:relativeRepository];
		relativeSettings.pushAfterCommit = NO;

		NSString *absoluteKey = [[[[NSURL fileURLWithPath:absolutePath isDirectory:YES] standardizedURL] URLByResolvingSymlinksInPath] path];
		NSString *relativeKey = [[[[workingDirectoryURL URLByAppendingPathComponent:@".git" isDirectory:YES] standardizedURL] URLByResolvingSymlinksInPath] path];
		NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *storedSettings = [defaults dictionaryForKey:defaultsKey];
		XCTAssertEqualObjects(storedSettings[absoluteKey][@"pushAfterCommit"], @YES);
		XCTAssertEqualObjects(storedSettings[relativeKey][@"pushAfterCommit"], @NO);
		XCTAssertEqual(storedSettings.count, (NSUInteger)2);

		// Fresh instances must re-derive the same repository identity. Use a
		// non-default sentinel for the relative path so a missing lookup cannot pass.
		PBWindowRepositoryWithoutGitURLs *absoluteReadBackRepository = [PBWindowRepositoryWithoutGitURLs new];
		absoluteReadBackRepository.testCommonGitDirectoryOutput = absolutePath;
		XCTAssertTrue([[PBRepositoryUISettings alloc] initWithRepository:absoluteReadBackRepository].pushAfterCommit);

		relativeSettings.pushAfterCommit = YES;
		PBWindowRepositoryWithoutGitURLs *relativeReadBackRepository = [PBWindowRepositoryWithoutGitURLs new];
		relativeReadBackRepository.testCommonGitDirectoryOutput = @".git";
		relativeReadBackRepository.testWorkingDirectoryURL = workingDirectoryURL;
		XCTAssertTrue([[PBRepositoryUISettings alloc] initWithRepository:relativeReadBackRepository].pushAfterCommit);
	} @finally {
		if (originalSettings)
			[defaults setObject:originalSettings forKey:defaultsKey];
		else
			[defaults removeObjectForKey:defaultsKey];
	}
}

- (void)testSourceViewBadgeColorsAndRenderingAcrossWindowStates
{
	PBSourceViewBadgeTestWindow *window = [[PBSourceViewBadgeTestWindow alloc]
		initWithContentRect:NSZeroRect
				  styleMask:NSWindowStyleMaskBorderless
					backing:NSBackingStoreBuffered
					  defer:NO];
	PBSourceViewBadgeTestCell *cell = [PBSourceViewBadgeTestCell new];
	cell.testWindow = window;

	cell.testBackgroundStyle = NSBackgroundStyleEmphasized;
	window.testKeyWindow = YES;
	XCTAssertEqualObjects([PBSourceViewBadge badgeColorForCell:cell], NSColor.whiteColor);
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell],
						  [PBSourceViewBadge badgeBackgroundColor]);

	window.testKeyWindow = NO;
	window.testMainWindow = YES;
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell],
						  [PBSourceViewBadge badgeHighlightColor]);
	window.testMainWindow = NO;
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell],
						  [PBSourceViewBadge badgeBackgroundColor]);

	cell.testBackgroundStyle = NSBackgroundStyleNormal;
	XCTAssertEqualObjects([PBSourceViewBadge badgeColorForCell:cell],
						  [PBSourceViewBadge badgeBackgroundColor]);
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell], NSColor.whiteColor);
	window.testMainWindow = YES;
	XCTAssertEqualObjects([PBSourceViewBadge badgeColorForCell:cell],
						  [PBSourceViewBadge badgeHighlightColor]);

	NSImage *checkedBadge = [PBSourceViewBadge checkedOutBadgeForCell:cell];
	NSImage *numericBadge = [PBSourceViewBadge numericBadge:123456 forCell:cell];
	NSImage *directBadge = [PBSourceViewBadge badge:@"7" forCell:cell];
	XCTAssertGreaterThan(checkedBadge.size.width, (CGFloat)0);
	XCTAssertGreaterThan(numericBadge.size.width, checkedBadge.size.width);
	XCTAssertGreaterThan(directBadge.size.height, (CGFloat)0);
	NSImageView *checkedPreview = [NSImageView imageViewWithImage:checkedBadge];
	NSImageView *numericPreview = [NSImageView imageViewWithImage:numericBadge];
	NSImageView *directPreview = [NSImageView imageViewWithImage:directBadge];
	NSStackView *badgePreview = [NSStackView stackViewWithViews:@[ checkedPreview, numericPreview, directPreview ]];
	badgePreview.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	badgePreview.spacing = 8;
	badgePreview.frame = NSMakeRect(0, 0, 260, 40);
	[self attachScreenshotOfView:badgePreview name:@"Source view badges across window states"];
}

- (void)testRepositorySettingsStoreReadsAndWritesLocalValues
{
	PBRepositorySettingsStore *store = [[PBRepositorySettingsStore alloc] initWithRepository:self.repository];
	NSError *error = nil;

	XCTAssertTrue([store setString:@"toolbar-value" forKey:@"gitx.test.toolbarValue" error:&error]);
	XCTAssertNil(error);
	XCTAssertEqualObjects([store stringForKey:@"gitx.test.toolbarValue"], @"toolbar-value");
	XCTAssertTrue([store setBool:YES forKey:@"gitx.test.toolbarEnabled" error:&error]);
	XCTAssertNil(error);
	XCTAssertTrue([store boolForKey:@"gitx.test.toolbarEnabled" defaultValue:NO]);
	XCTAssertTrue([store setBool:NO forKey:@"gitx.test.toolbarEnabled" error:&error]);
	XCTAssertNil(error);
	XCTAssertFalse([store boolForKey:@"gitx.test.toolbarEnabled" defaultValue:YES]);
	XCTAssertTrue([store setString:@"develop" forKey:@"gitx.primaryBranch" error:&error]);
	XCTAssertNil(error);
	XCTAssertEqualObjects(store.detectedPrimaryBranch, @"develop");
	[self git:@[ @"config", @"--local", @"--unset", @"gitx.primaryBranch" ] directory:self.repositoryURL];
	[self git:@[ @"update-ref", @"refs/remotes/origin/main", @"HEAD" ] directory:self.repositoryURL];
	[self git:@[ @"symbolic-ref", @"refs/remotes/origin/HEAD", @"refs/remotes/origin/main" ] directory:self.repositoryURL];
	XCTAssertEqualObjects(store.detectedPrimaryBranch, @"main");
	[self git:@[ @"symbolic-ref", @"--delete", @"refs/remotes/origin/HEAD" ] directory:self.repositoryURL];
	[self git:@[ @"update-ref", @"-d", @"refs/remotes/origin/main" ] directory:self.repositoryURL];

	[self git:@[ @"branch", @"-m", @"topic" ] directory:self.repositoryURL];
	[self git:@[ @"branch", @"master" ] directory:self.repositoryURL];
	[self.repository reloadRefs];
	PBRepositorySettingsStore *masterFallbackStore = [[PBRepositorySettingsStore alloc] initWithRepository:self.repository];
	XCTAssertEqualObjects(masterFallbackStore.detectedPrimaryBranch, @"master");
	[self git:@[ @"branch", @"-D", @"master" ] directory:self.repositoryURL];
	[self git:@[ @"tag", @"main" ] directory:self.repositoryURL];
	[self.repository reloadRefs];
	[self.repository readCurrentBranch];
	PBRepositorySettingsStore *tagOnlyStore = [[PBRepositorySettingsStore alloc] initWithRepository:self.repository];
	XCTAssertEqualObjects(tagOnlyStore.detectedPrimaryBranch, @"topic");
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

	PBWindowHookResponse = NSModalResponseOK;
	__block BOOL retried = NO;
	[self.controller showCommitHookFailedSheet:@"Hook"
									  infoText:@"Failed"
								  retryHandler:^{
									  retried = YES;
								  }];
	XCTAssertTrue(retried);
	PBWindowHookResponse = NSModalResponseCancel;
	__block BOOL retriedAfterCancel = NO;
	[self.controller showCommitHookFailedSheet:@"Hook"
									  infoText:@"Failed"
								  retryHandler:^{
									  retriedAfterCancel = YES;
								  }];
	XCTAssertFalse(retriedAfterCancel);
	XCTAssertEqual(PBWindowHookCount, (NSUInteger)2);

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
	NSUInteger baseline = self.controller.synchronizeCount;
	[self.controller applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:NSApp]];
	[self pumpRunLoopFor:0.1];
	XCTAssertEqual(self.controller.synchronizeCount, baseline);

	PBWindowSnapshotData = [@"snapshot-b" dataUsingEncoding:NSUTF8StringEncoding];
	[self.controller refreshIfRepositoryChangedSinceLastActivation];
	[self pumpRunLoopFor:0.1];
	XCTAssertGreaterThan(self.controller.synchronizeCount, baseline);

	NSUInteger changedCount = self.controller.synchronizeCount;
	PBWindowSnapshotData = [@"snapshot-c" dataUsingEncoding:NSUTF8StringEncoding];
	[self.controller refreshIfRepositoryChangedSinceLastActivation];
	[NSUserDefaults.standardUserDefaults setObject:@NO forKey:@"PBRefreshOnApplicationFocus"];
	[self.controller refreshPreferenceDidChange:nil];
	[self pumpRunLoopFor:0.1];
	XCTAssertEqual(self.controller.synchronizeCount, changedCount);

	PBWindowSnapshotError = self.repository.testError;
	[NSUserDefaults.standardUserDefaults setObject:@YES forKey:@"PBRefreshOnApplicationFocus"];
	[self.controller refreshPreferenceDidChange:nil];
	[self pumpRunLoopFor:0.1];
	XCTAssertGreaterThan(self.controller.synchronizeCount, changedCount);
}

@end

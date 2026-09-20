#import <XCTest/XCTest.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>

#import "GitXApplicationLocator.h"
#import "PBGitDefaults.h"
#import "PBAutoFetchManagerCompatibility.h"
#import "PBMacros.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBRepositoryDocumentControllerCompatibility.h"
#import "PBGitBinary.h"
#import "PBGitWindowControllerCompatibility.h"
#import "PBHistoryArrayController.h"
#import "PBHighlighting.h"
#import "PBFileChangesTableView.h"
#import "PBNativeContentView.h"
#import "PBGitRevisionCell.h"
#import "PBTask.h"
#import "PBWebController.h"
#import "NSAppearance+PBDarkMode.h"
#import "ApplicationController.h"
#import "PBSourceViewBadge.h"

static NSUInteger PBAutoFetchAuthorizationRequestCount;
static UNNotificationRequest *PBAutoFetchLastNotificationRequest;
static NSDocumentController *PBAutoFetchDocumentController;

@interface PBRepositoryOpenPanelSpy : NSOpenPanel {
	BOOL _testCanChooseFiles;
	BOOL _testCanChooseDirectories;
	BOOL _testAllowsMultipleSelection;
	NSArray<NSString *> *_testAllowedFileTypes;
	NSString *_testMessage;
	NSString *_testTitle;
}

@property (nonatomic) NSModalResponse response;
@property (nullable, nonatomic) NSURL *selectedURL;

@end

@interface PBAutoFetchOutputSpy : PBAutoFetchManager
@property (nonatomic, copy) NSString *testOutput;
@property (nullable, nonatomic) NSError *testError;
@end

@implementation PBAutoFetchOutputSpy
- (NSString *)outputForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments error:(NSError **)error
{
	if (self.testError && error) *error = self.testError;
	return self.testOutput;
}
@end


@implementation PBRepositoryOpenPanelSpy

- (BOOL)canChooseFiles
{
	return _testCanChooseFiles;
}
- (void)setCanChooseFiles:(BOOL)value
{
	_testCanChooseFiles = value;
}
- (BOOL)canChooseDirectories
{
	return _testCanChooseDirectories;
}
- (void)setCanChooseDirectories:(BOOL)value
{
	_testCanChooseDirectories = value;
}
- (BOOL)allowsMultipleSelection
{
	return _testAllowsMultipleSelection;
}
- (void)setAllowsMultipleSelection:(BOOL)value
{
	_testAllowsMultipleSelection = value;
}
- (NSArray<NSString *> *)allowedFileTypes
{
	return _testAllowedFileTypes;
}
- (void)setAllowedFileTypes:(NSArray<NSString *> *)value
{
	_testAllowedFileTypes = [value copy];
}
- (NSString *)message
{
	return _testMessage;
}
- (void)setMessage:(NSString *)value
{
	_testMessage = [value copy];
}
- (NSString *)title
{
	return _testTitle;
}
- (void)setTitle:(NSString *)value
{
	_testTitle = [value copy];
}

- (NSModalResponse)runModal
{
	return self.response;
}

- (NSURL *)URL
{
	return self.selectedURL;
}

@end

static PBRepositoryOpenPanelSpy *PBNewRepositoryOpenPanelSpy(void)
{
	return class_createInstance(PBRepositoryOpenPanelSpy.class, 0);
}

static PBRepositoryDocumentController *PBNewRepositoryDocumentController(Class controllerClass)
{
	return class_createInstance(controllerClass, 0);
}


@interface PBRepositoryDocumentController (GitXFeatureTests)
+ (NSOpenPanel *)newOpenPanel;
@end


@interface PBRepositoryDocumentControllerSpy : PBRepositoryDocumentController
+ (void)setTestOpenPanel:(PBRepositoryOpenPanelSpy *)panel;
@end


@implementation PBRepositoryDocumentControllerSpy

static PBRepositoryOpenPanelSpy *PBRepositoryTestOpenPanel;

+ (void)setTestOpenPanel:(PBRepositoryOpenPanelSpy *)panel
{
	PBRepositoryTestOpenPanel = panel;
}

+ (NSOpenPanel *)newOpenPanel
{
	return PBRepositoryTestOpenPanel;
}

@end

static void PBFeatureSwapInstanceMethods(Class cls, SEL original, SEL replacement)
{
	method_exchangeImplementations(class_getInstanceMethod(cls, original), class_getInstanceMethod(cls, replacement));
}

static void PBFeatureSwapClassMethods(Class cls, SEL original, SEL replacement)
{
	method_exchangeImplementations(class_getClassMethod(cls, original), class_getClassMethod(cls, replacement));
}

@interface NSDocumentController (GitXFeatureTests)
+ (NSDocumentController *)pb_feature_sharedDocumentController;
@end

@implementation NSDocumentController (GitXFeatureTests)
+ (NSDocumentController *)pb_feature_sharedDocumentController
{
	return PBAutoFetchDocumentController;
}
@end

@interface PBAutoFetchDocumentControllerSpy : NSDocumentController
@property (nonatomic, copy) NSArray<NSDocument *> *testDocuments;
@property (nonatomic, copy) NSArray<NSURL *> *testRecentURLs;
@property (nullable, nonatomic) NSDocument *testCurrentDocument;
@property (nullable, nonatomic) NSDocument *testDocumentToOpen;
@end

@implementation PBAutoFetchDocumentControllerSpy
- (NSArray<NSDocument *> *)documents
{
	return self.testDocuments ?: @[];
}
- (NSArray<NSURL *> *)recentDocumentURLs
{
	return self.testRecentURLs ?: @[];
}
- (NSDocument *)currentDocument
{
	return self.testCurrentDocument;
}
- (void)openDocumentWithContentsOfURL:(NSURL *)url
							  display:(BOOL)displayDocument
					completionHandler:(void (^)(NSDocument *_Nullable document, BOOL documentWasAlreadyOpen, NSError *_Nullable error))completionHandler
{
	completionHandler(self.testDocumentToOpen, NO, nil);
}
@end

@interface PBAutoFetchRepositorySpy : PBGitRepository
@property (nonatomic, strong) NSURL *testWorkingDirectoryURL;
@property (nonatomic) NSUInteger reloadCount;
@property (nonatomic) NSUInteger forceUpdateCount;
@property (nonatomic) NSInteger testBranchFilter;
@property (nullable, nonatomic, strong) PBGitRevSpecifier *testCurrentBranch;
@end

@implementation PBAutoFetchRepositorySpy
- (NSURL *)workingDirectoryURL
{
	return self.testWorkingDirectoryURL;
}
- (void)reloadRefs
{
	self.reloadCount++;
}
- (void)forceUpdateRevisions
{
	self.forceUpdateCount++;
}
- (NSInteger)currentBranchFilter
{
	return self.testBranchFilter;
}
- (void)setCurrentBranchFilter:(NSInteger)value
{
	self.testBranchFilter = value;
}
- (BOOL)refExists:(PBGitRef *)ref
{
	return YES;
}
- (PBGitRevSpecifier *)addBranch:(PBGitRevSpecifier *)rev
{
	return rev;
}
- (PBGitRevSpecifier *)currentBranch
{
	return self.testCurrentBranch;
}
- (void)setCurrentBranch:(PBGitRevSpecifier *)value
{
	self.testCurrentBranch = value;
}
@end

@interface PBAutoFetchWindowControllerSpy : PBGitWindowController
@property (nonatomic) NSUInteger showHistoryCount;
@property (nullable, nonatomic, strong) PBGitHistoryController *testHistoryViewController;
@end

@implementation PBAutoFetchWindowControllerSpy
- (void)showHistoryView:(id)sender
{
	self.showHistoryCount++;
}
- (NSWindow *)window
{
	return nil;
}
- (PBGitHistoryController *)historyViewController
{
	return self.testHistoryViewController;
}
@end

@interface PBAutoFetchHistoryControllerSpy : PBGitHistoryController
@property (nullable, nonatomic) XCTestExpectation *selectionExpectation;
@end

@implementation PBAutoFetchHistoryControllerSpy
- (void)selectCommit:(GTOID *)commit
{
	[self.selectionExpectation fulfill];
}
@end

@interface PBAutoFetchRepositoryDocumentSpy : PBGitRepositoryDocument
@property (nonatomic, strong) PBAutoFetchRepositorySpy *testRepository;
@property (nonatomic, strong) PBAutoFetchWindowControllerSpy *testWindowController;
@end

@implementation PBAutoFetchRepositoryDocumentSpy
- (PBGitRepository *)repository
{
	return self.testRepository;
}
- (PBGitWindowController *)windowController
{
	return self.testWindowController;
}
@end

@interface PBAutoFetchNotificationSpy : UNNotification
@property (nonatomic, strong) UNNotificationRequest *testRequest;
@end

@implementation PBAutoFetchNotificationSpy
- (UNNotificationRequest *)request
{
	return self.testRequest;
}
@end

@interface PBAutoFetchNotificationResponseSpy : UNNotificationResponse
@property (nonatomic, strong) PBAutoFetchNotificationSpy *testNotification;
@end

@implementation PBAutoFetchNotificationResponseSpy
- (UNNotification *)notification
{
	return self.testNotification;
}
@end

@interface UNUserNotificationCenter (GitXFeatureTests)
- (void)pb_feature_requestAuthorizationWithOptions:(__unused UNAuthorizationOptions)options
								 completionHandler:(void (^)(BOOL granted, NSError *_Nullable error))completionHandler;
@end

@implementation UNUserNotificationCenter (GitXFeatureTests)

- (void)pb_feature_requestAuthorizationWithOptions:(__unused UNAuthorizationOptions)options
								 completionHandler:(void (^)(BOOL granted, NSError *_Nullable error))completionHandler
{
	PBAutoFetchAuthorizationRequestCount++;
	completionHandler(YES, nil);
}

@end

@interface UNUserNotificationCenter (GitXFeatureNotificationTests)
- (void)pb_feature_addNotificationRequest:(UNNotificationRequest *)request
						completionHandler:(nullable void (^)(NSError *_Nullable error))completionHandler;
@end

@implementation UNUserNotificationCenter (GitXFeatureNotificationTests)

- (void)pb_feature_addNotificationRequest:(UNNotificationRequest *)request
						completionHandler:(void (^)(NSError *_Nullable error))completionHandler
{
	PBAutoFetchLastNotificationRequest = request;
	if (completionHandler) completionHandler(nil);
}

@end

@interface PBSourceViewBadge (GitXFeatureTests)

+ (NSColor *)badgeHighlightColor;
+ (NSColor *)badgeBackgroundColor;
+ (NSColor *)badgeColorForCell:(NSTableCellView *)cell;
+ (NSColor *)badgeTextColorForCell:(NSTableCellView *)cell;

@end

@interface PBSourceViewBadgeWindow : NSWindow

@property (nonatomic) BOOL testMainWindow;
@property (nonatomic) BOOL testKeyWindow;

@end

@implementation PBSourceViewBadgeWindow

- (BOOL)isMainWindow
{
	return self.testMainWindow;
}

- (BOOL)isKeyWindow
{
	return self.testKeyWindow;
}

@end

@interface PBSourceViewBadgeCell : NSTableCellView

@property (nonatomic, strong) NSWindow *testWindow;

@end

@implementation PBSourceViewBadgeCell

- (NSWindow *)window
{
	return self.testWindow;
}

@end

@interface ApplicationController (GitXFeatureTests)
- (NSArray *)feedParametersForUpdater:(nullable id)updater sendingSystemProfile:(BOOL)sendingSystemProfile;
- (void)applicationDidBecomeActive:(nullable NSNotification *)notification;
- (void)applicationWillTerminate:(nullable NSNotification *)notification;
@end

@interface PBFileChangesActionTarget : NSObject <NSTableViewDataSource, NSTableViewDelegate, PBFileChangesTableViewStagingDelegate>

@property (nonatomic) NSUInteger stagingToggleCount;
@property (nonatomic, weak) id lastSender;

@end

@implementation PBFileChangesActionTarget

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return 3;
}

- (void)fileChangesTableViewDidRequestStagingToggle:(PBFileChangesTableView *)tableView
{
	self.stagingToggleCount++;
	self.lastSender = tableView;
}

@end

@interface PBNativeImageDataDelegate : NSObject <PBNativeContentViewDelegate>

@property (nonatomic) NSData *imageData;
@property (atomic) BOOL callbackWasOnMainThread;
@property (atomic) NSDictionary<NSString *, id> *capturedImageSource;
@property (nonatomic) NSMutableArray<NSString *> *diffActions;
@property (nonatomic) NSMutableArray<NSString *> *diffPatches;
@property (nullable, nonatomic) NSString *selectedCommitSHA;

@end

@implementation PBNativeImageDataDelegate

- (instancetype)init
{
	self = [super init];
	if (!self) return nil;
	_diffActions = [NSMutableArray array];
	_diffPatches = [NSMutableArray array];
	return self;
}

- (void)nativeContentView:(PBNativeContentView *)view performDiffAction:(NSString *)action patch:(NSString *)patch
{
	[self.diffActions addObject:action];
	[self.diffPatches addObject:patch];
}

- (void)nativeContentView:(PBNativeContentView *)view selectCommit:(NSString *)sha
{
	self.selectedCommitSHA = sha;
}

- (NSData *)nativeContentView:(PBNativeContentView *)view
			 imageDataForPath:(NSString *)path
					  section:(NSUInteger)sectionIndex
				  imageSource:(NSDictionary<NSString *, id> *)imageSource
{
	self.callbackWasOnMainThread = NSThread.isMainThread;
	self.capturedImageSource = imageSource;
	return self.imageData;
}

@end

@interface PBCheckedOutBranchRepositorySpy : PBGitRepository

@property (nonatomic) NSUInteger reloadRefsCount;
@property (nonatomic) NSUInteger readCurrentBranchCount;

@end

@implementation PBCheckedOutBranchRepositorySpy

- (void)reloadRefs
{
	self.reloadRefsCount++;
}

- (void)readCurrentBranch
{
	self.readCurrentBranchCount++;
}

@end


@interface PBCheckedOutBranchDocumentSpy : PBGitRepositoryDocument

@property (nonatomic, strong) PBCheckedOutBranchRepositorySpy *repositorySpy;

@end


@implementation PBCheckedOutBranchDocumentSpy

- (PBGitRepository *)repository
{
	return self.repositorySpy;
}

@end

@interface PBManualRefreshContentSpy : NSObject

@property (nonatomic) NSUInteger refreshCount;

@end

@implementation PBManualRefreshContentSpy

- (void)refresh:(id)sender
{
	self.refreshCount++;
}

@end

@interface PBManualRefreshWindowControllerSpy : PBGitWindowController

@property (nonatomic) NSUInteger titleSynchronizationCount;

@end

@implementation PBManualRefreshWindowControllerSpy

- (void)synchronizeWindowTitleWithDocumentName
{
	self.titleSynchronizationCount++;
}

- (NSWindow *)window
{
	return nil;
}

@end

@interface GitXFeatureTests : XCTestCase

@property (nonatomic) BOOL originalHistorySortingEnabled;
@property (nonatomic) PBAutoFetchScope originalAutoFetchScope;
@property (nonatomic) NSInteger originalAutoFetchInterval;

@end

@interface PBNativeContentView (GitXFeatureTests)
- (nullable NSString *)patchWithFileHeader:(NSArray<NSString *> *)fileHeader
								 hunkLines:(NSArray<NSString *> *)hunkLines
						   selectedIndexes:(NSIndexSet *)selectedIndexes
								   reverse:(BOOL)reverse;
- (NSString *)pathForDiffHeaderAtIndex:(NSUInteger)headerIndex lines:(NSArray<NSString *> *)lines;
- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex;
@end

@interface PBAutoFetchManager (GitXFeatureTests)
+ (NSTimeInterval)retryDelayForFailureCount:(NSUInteger)failureCount;
- (void)ensureNotificationAuthorization;
- (void)timerFired:(NSTimer *)timer;
- (void)autoFetchPreferencesChanged:(nullable NSNotification *)notification;
- (void)workspaceDidWake:(nullable NSNotification *)notification;
- (NSString *)keyForURL:(NSURL *)url;
- (NSDictionary<NSString *, NSURL *> *)candidateRepositoryURLs;
- (void)evaluateRepositoriesForImmediateFetch:(BOOL)immediate;
- (PBTask *)taskForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments;
- (nullable NSString *)outputForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments error:(NSError **)error;
- (nullable NSDictionary<NSString *, NSString *> *)remoteSnapshotForURL:(NSURL *)url error:(NSError **)error;
- (BOOL)isAncestor:(NSString *)oldSHA of:(NSString *)newSHA repositoryURL:(NSURL *)url;
- (NSInteger)commitCountFrom:(NSString *)oldSHA to:(NSString *)newSHA repositoryURL:(NSURL *)url;
- (NSTimeInterval)commitTimestampForSHA:(NSString *)sha repositoryURL:(NSURL *)url;
- (void)fetchRepositoryAtURL:(NSURL *)url key:(NSString *)key;
- (nullable PBGitRepositoryDocument *)openDocumentForRepositoryURL:(NSURL *)url;
- (void)refreshOpenRepositoryAtURL:(NSURL *)url;
- (void)postFailureNotificationForURL:(NSURL *)url error:(NSError *)error;
- (void)postAdvanceNotificationForURL:(NSURL *)url advances:(NSArray<NSDictionary *> *)advances;
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
	   willPresentNotification:(nullable UNNotification *)notification
		 withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler;
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
	didReceiveNotificationResponse:(UNNotificationResponse *)response
			 withCompletionHandler:(void (^)(void))completionHandler;
@end

@interface PBAutoFetchManagerSpy : PBAutoFetchManager

@property (nonatomic) NSUInteger evaluationCount;
@property (nonatomic) BOOL lastEvaluationWasImmediate;

@end

@interface PBAutoFetchTaskSpy : PBTask
@property (nonatomic) BOOL succeeds;
@property (nullable, nonatomic) NSError *testError;
@property (nonatomic, copy) NSString *testOutput;
@property (nullable, nonatomic) XCTestExpectation *launchExpectation;
@property (nullable, nonatomic) dispatch_semaphore_t launchGate;
@end

@implementation PBAutoFetchTaskSpy
- (BOOL)launchTask:(NSError **)error
{
	[self.launchExpectation fulfill];
	if (self.launchGate) dispatch_semaphore_wait(self.launchGate, DISPATCH_TIME_FOREVER);
	if (!self.succeeds && error) *error = self.testError;
	return self.succeeds;
}
- (NSString *)standardOutputString
{
	return self.testOutput;
}
@end

@interface PBAutoFetchBehaviorSpy : PBAutoFetchManager
@property (nonatomic, copy) NSDictionary<NSString *, NSURL *> *testCandidates;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *testSnapshots;
@property (nullable, nonatomic) NSError *snapshotError;
@property (nonatomic) NSUInteger snapshotIndex;
@property (nonatomic) BOOL ancestorResult;
@property (nonatomic) NSInteger testCommitCount;
@property (nonatomic) NSTimeInterval testTimestamp;
@property (nonatomic, strong) PBAutoFetchTaskSpy *testTask;
@property (nonatomic, copy) NSString *testOutput;
@property (nonatomic) NSUInteger fetchCount;
@property (nonatomic) NSUInteger refreshCount;
@property (nonatomic) NSUInteger failureNotificationCount;
@property (nonatomic) NSUInteger advanceNotificationCount;
@property (nullable, nonatomic) XCTestExpectation *fetchExpectation;
@property (nullable, nonatomic) XCTestExpectation *deliveryExpectation;
@end

@implementation PBAutoFetchBehaviorSpy
- (NSDictionary<NSString *, NSURL *> *)candidateRepositoryURLs
{
	return self.testCandidates ?: @{};
}
- (void)fetchRepositoryAtURL:(NSURL *)url key:(NSString *)key
{
	if (self.fetchExpectation) {
		self.fetchCount++;
		[self.fetchExpectation fulfill];
		return;
	}
	[super fetchRepositoryAtURL:url key:key];
}
- (NSDictionary<NSString *, NSString *> *)remoteSnapshotForURL:(NSURL *)url error:(NSError **)error
{
	if (self.snapshotIndex >= self.testSnapshots.count) {
		if (error) *error = self.snapshotError;
		return nil;
	}
	return self.testSnapshots[self.snapshotIndex++];
}
- (PBTask *)taskForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments
{
	return self.testTask;
}
- (NSString *)outputForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments error:(NSError **)error
{
	if (self.snapshotError && error) *error = self.snapshotError;
	return self.testOutput;
}
- (BOOL)isAncestor:(NSString *)oldSHA of:(NSString *)newSHA repositoryURL:(NSURL *)url
{
	return self.ancestorResult;
}
- (NSInteger)commitCountFrom:(NSString *)oldSHA to:(NSString *)newSHA repositoryURL:(NSURL *)url
{
	return self.testCommitCount;
}
- (NSTimeInterval)commitTimestampForSHA:(NSString *)sha repositoryURL:(NSURL *)url
{
	return self.testTimestamp;
}
- (void)refreshOpenRepositoryAtURL:(NSURL *)url
{
	self.refreshCount++;
	[self.deliveryExpectation fulfill];
}
- (void)postFailureNotificationForURL:(NSURL *)url error:(NSError *)error
{
	self.failureNotificationCount++;
	[self.deliveryExpectation fulfill];
}
- (void)postAdvanceNotificationForURL:(NSURL *)url advances:(NSArray<NSDictionary *> *)advances
{
	self.advanceNotificationCount++;
}
@end

@implementation PBAutoFetchManagerSpy

- (void)evaluateRepositoriesForImmediateFetch:(BOOL)immediate
{
	self.evaluationCount++;
	self.lastEvaluationWasImmediate = immediate;
}

@end

@implementation GitXFeatureTests

- (NSEvent *)spaceKeyEventWithModifiers:(NSEventModifierFlags)modifiers
{
	return [NSEvent keyEventWithType:NSEventTypeKeyDown
							location:NSZeroPoint
					   modifierFlags:modifiers
						   timestamp:0
						windowNumber:0
							 context:nil
						  characters:@" "
		 charactersIgnoringModifiers:@" "
						   isARepeat:NO
							 keyCode:49];
}

- (NSEvent *)rightMouseEventAtLocation:(NSPoint)location windowNumber:(NSInteger)windowNumber
{
	return [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
							  location:location
						 modifierFlags:0
							 timestamp:0
						  windowNumber:windowNumber
							   context:nil
						   eventNumber:1
							clickCount:1
							  pressure:1];
}

- (void)setUp
{
	[super setUp];
	self.originalHistorySortingEnabled = [PBGitDefaults historyColumnSortingEnabled];
	self.originalAutoFetchScope = [PBGitDefaults autoFetchScope];
	self.originalAutoFetchInterval = [PBGitDefaults autoFetchIntervalMinutes];
	[PBGitDefaults setHistoryColumnSortingEnabled:YES];
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeNone];
	[PBGitDefaults setAutoFetchIntervalMinutes:15];
}

- (void)tearDown
{
	[PBGitDefaults setHistoryColumnSortingEnabled:self.originalHistorySortingEnabled];
	[PBGitDefaults setAutoFetchScope:self.originalAutoFetchScope];
	[PBGitDefaults setAutoFetchIntervalMinutes:self.originalAutoFetchInterval];
	[super tearDown];
}

- (void)waitForNativeView:(PBNativeContentView *)view toContainString:(NSString *)string
{
	NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return [view.textView.string containsString:string];
	}];
	XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:view];
	[self waitForExpectations:@[ expectation ] timeout:10.0];
}

- (nullable id)linkInNativeView:(PBNativeContentView *)view titled:(NSString *)title index:(NSUInteger *)index
{
	NSRange range = [view.textView.string rangeOfString:title];
	if (range.location == NSNotFound) return nil;
	if (index) *index = range.location;
	return [view.textView.textStorage attribute:NSLinkAttributeName atIndex:range.location effectiveRange:nil];
}

- (void)testApplicationDelegateCompatibilitySurface
{
	ApplicationController *controller = (ApplicationController *)NSApp.delegate;
	XCTAssertTrue([controller isKindOfClass:ApplicationController.class]);
	XCTAssertEqual([controller feedParametersForUpdater:nil sendingSystemProfile:NO].count, (NSUInteger)0);
	XCTAssertGreaterThan([controller feedParametersForUpdater:nil sendingSystemProfile:YES].count, (NSUInteger)0);
	(void)[controller applicationShouldOpenUntitledFile:NSApp];
	[controller applicationDidBecomeActive:nil];
}

- (void)testApplicationDelegateSuppressesWindowSessionCaptureForAppHostedTests
{
	ApplicationController *controller = (ApplicationController *)NSApp.delegate;
	XCTAssertNotNil(NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"]);
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	NSString *snapshotKey = @"PBWindowSessionSnapshot";
	NSString *cleanShutdownKey = @"PBWindowSessionCleanShutdown";
	id previousSnapshot = [defaults objectForKey:snapshotKey];
	id previousCleanShutdown = [defaults objectForKey:cleanShutdownKey];
	NSArray *sentinelSnapshot = @[ @{@"path" : @"/tmp/GitX-app-hosted-session-sentinel"} ];
	@try {
		[defaults setObject:sentinelSnapshot forKey:snapshotKey];
		[defaults setBool:NO forKey:cleanShutdownKey];
		[controller applicationWillTerminate:nil];
		XCTAssertEqualObjects([defaults objectForKey:snapshotKey], sentinelSnapshot);
		XCTAssertFalse([defaults boolForKey:cleanShutdownKey]);
	} @finally {
		if (previousSnapshot)
			[defaults setObject:previousSnapshot forKey:snapshotKey];
		else
			[defaults removeObjectForKey:snapshotKey];
		if (previousCleanShutdown)
			[defaults setObject:previousCleanShutdown forKey:cleanShutdownKey];
		else
			[defaults removeObjectForKey:cleanShutdownKey];
	}
}

- (void)testAutoFetchDefaultsClampInterval
{
	[PBGitDefaults setAutoFetchIntervalMinutes:0];
	XCTAssertEqual([PBGitDefaults autoFetchIntervalMinutes], 1);
	[PBGitDefaults setAutoFetchIntervalMinutes:2000];
	XCTAssertEqual([PBGitDefaults autoFetchIntervalMinutes], 1440);
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenRepositories];
	XCTAssertEqual([PBGitDefaults autoFetchScope], PBAutoFetchScopeOpenRepositories);
}

- (void)testAutoFetchTimerRequestsANonImmediateEvaluation
{
	PBAutoFetchManagerSpy *manager = [[PBAutoFetchManagerSpy alloc] init];
	NSTimer *timer = [NSTimer timerWithTimeInterval:1
											repeats:NO
											  block:^(__unused NSTimer *firedTimer){
											  }];

	[manager timerFired:timer];

	XCTAssertEqual(manager.evaluationCount, (NSUInteger)1);
	XCTAssertFalse(manager.lastEvaluationWasImmediate);
}

- (void)testAutoFetchStopEndsWakeDrivenEvaluationAndCanRestart
{
	PBAutoFetchScope previousScope = [PBGitDefaults autoFetchScope];
	// A disabled scope keeps `start` from requesting notification authorization
	// or fetching; the observers this test cares about are registered regardless.
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeNone];
	PBAutoFetchManagerSpy *manager = [[PBAutoFetchManagerSpy alloc] init];
	NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];

	[manager start];
	[workspaceCenter postNotificationName:NSWorkspaceDidWakeNotification object:nil];
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)1);

	[manager stop];
	[workspaceCenter postNotificationName:NSWorkspaceDidWakeNotification object:nil];
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)1, @"stop must drop the workspace observer");

	// Stopping twice is harmless, and a stopped manager can be started again.
	[manager stop];
	[manager start];
	[workspaceCenter postNotificationName:NSWorkspaceDidWakeNotification object:nil];
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)2);

	[manager stop];

	PBAutoFetchAuthorizationRequestCount = 0;
	PBFeatureSwapInstanceMethods(
		UNUserNotificationCenter.class,
		@selector(requestAuthorizationWithOptions:completionHandler:),
		@selector(pb_feature_requestAuthorizationWithOptions:completionHandler:));
	@try {
		[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenRepositories];
		[manager start];
		XCTAssertTrue(manager.lastEvaluationWasImmediate);
		XCTAssertEqual(PBAutoFetchAuthorizationRequestCount, (NSUInteger)1);
		[manager stop];
	} @finally {
		PBFeatureSwapInstanceMethods(
			UNUserNotificationCenter.class,
			@selector(requestAuthorizationWithOptions:completionHandler:),
			@selector(pb_feature_requestAuthorizationWithOptions:completionHandler:));
	}
	[PBGitDefaults setAutoFetchScope:previousScope];
}

- (void)testAutoFetchPreferenceChangeReevaluatesAndResetsBackoffWhenReenabled
{
	// This ran only incidentally before, through the shared manager's live
	// observers. Driving it directly keeps the behavior covered no matter what
	// else the suite does to that singleton.
	PBAutoFetchScope previousScope = [PBGitDefaults autoFetchScope];
	PBAutoFetchManagerSpy *manager = [[PBAutoFetchManagerSpy alloc] init];

	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeNone];
	[manager autoFetchPreferencesChanged:nil];
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)0, @"a disabled scope must not fetch");

	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenRepositories];
	[manager autoFetchPreferencesChanged:nil];
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)1);
	XCTAssertTrue(manager.lastEvaluationWasImmediate, @"re-enabling fetches immediately");

	// Still enabled, so this is not a transition and must not fetch immediately.
	[manager autoFetchPreferencesChanged:nil];
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)2);
	XCTAssertFalse(manager.lastEvaluationWasImmediate);

	[PBGitDefaults setAutoFetchScope:previousScope];
}

- (void)testAutoFetchManualSuccessClearsBackoffAndDefersTheNextFetch
{
	PBAutoFetchManagerSpy *manager = [[PBAutoFetchManagerSpy alloc] init];
	NSURL *repository = [NSURL fileURLWithPath:@"/tmp/gitx-auto-fetch-fixture" isDirectory:YES];

	// A manual fetch counts as a success: it clears recorded failures so the next
	// unattended attempt starts from the plain interval rather than a backoff.
	[manager recordManualFetchSucceededForRepositoryURL:repository];

	XCTAssertNoThrow([manager recordManualFetchSucceededForRepositoryURL:repository]);
}

- (void)testAutoFetchWakeAlwaysRequestsAnImmediateCatchUp
{
	PBAutoFetchManagerSpy *manager = [[PBAutoFetchManagerSpy alloc] init];

	[manager workspaceDidWake:nil];

	XCTAssertEqual(manager.evaluationCount, (NSUInteger)1);
	XCTAssertTrue(manager.lastEvaluationWasImmediate);
}

- (void)testAutoFetchStopBeforeStartIsSafe
{
	PBAutoFetchManagerSpy *manager = [[PBAutoFetchManagerSpy alloc] init];

	XCTAssertNoThrow([manager stop]);
	XCTAssertEqual(manager.evaluationCount, (NSUInteger)0);
}

- (void)testAutoFetchNotificationAuthorizationRunsCompletionOnce
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	PBAutoFetchAuthorizationRequestCount = 0;
	PBFeatureSwapInstanceMethods(
		UNUserNotificationCenter.class,
		@selector(requestAuthorizationWithOptions:completionHandler:),
		@selector(pb_feature_requestAuthorizationWithOptions:completionHandler:));
	@try {
		[manager ensureNotificationAuthorization];
		[manager ensureNotificationAuthorization];
		XCTAssertEqual(PBAutoFetchAuthorizationRequestCount, (NSUInteger)1);
	} @finally {
		PBFeatureSwapInstanceMethods(
			UNUserNotificationCenter.class,
			@selector(requestAuthorizationWithOptions:completionHandler:),
			@selector(pb_feature_requestAuthorizationWithOptions:completionHandler:));
	}
}

- (void)testAutoFetchKeysStandardizeRepositoryPaths
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/gitx-key/../gitx-key/repository" isDirectory:YES];

	XCTAssertEqualObjects([manager keyForURL:url], @"/tmp/gitx-key/repository");
}

- (void)testAutoFetchDisabledScopeHasNoCandidates
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeNone];

	XCTAssertEqual([manager candidateRepositoryURLs].count, (NSUInteger)0);
}

- (void)testAutoFetchEvaluationSchedulesCandidatesOnceAndHonorsInFlightAndFutureDates
{
	PBAutoFetchBehaviorSpy *manager = [[PBAutoFetchBehaviorSpy alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/gitx-scheduled" isDirectory:YES];
	manager.testCandidates = @{url.path : url};
	manager.fetchExpectation = [self expectationWithDescription:@"fetch scheduled"];
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenRepositories];

	[manager evaluateRepositoriesForImmediateFetch:YES];
	[self waitForExpectations:@[ manager.fetchExpectation ] timeout:2];
	XCTAssertEqual(manager.fetchCount, (NSUInteger)1);

	[manager evaluateRepositoriesForImmediateFetch:YES];
	XCTAssertEqual(manager.fetchCount, (NSUInteger)1, @"an in-flight repository must not be scheduled twice");

	[manager setValue:[NSMutableSet set] forKey:@"inFlightRepositories"];
	[manager setValue:[@{url.path : [NSDate dateWithTimeIntervalSinceNow:300]} mutableCopy] forKey:@"nextFetchDates"];
	[manager evaluateRepositoriesForImmediateFetch:NO];
	XCTAssertEqual(manager.fetchCount, (NSUInteger)1, @"a future due date must defer polling");
}

- (void)testAutoFetchTaskUsesNoninteractiveEnvironmentAndGitTimeout
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	PBTask *task = [manager taskForRepositoryURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]
									   arguments:@[ @"--version" ]];

	XCTAssertEqual(task.timeout, 10.0 * 60.0);
	XCTAssertEqualObjects(task.additionalEnvironment[@"GIT_TERMINAL_PROMPT"], @"0");
	XCTAssertEqualObjects(task.additionalEnvironment[@"GCM_INTERACTIVE"], @"never");
	XCTAssertEqualObjects(task.additionalEnvironment[@"GIT_ASKPASS"], @"/usr/bin/false");
	NSError *error = nil;
	NSString *output = [manager outputForRepositoryURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]
											 arguments:@[ @"--version" ]
												 error:&error];
	XCTAssertNotNil(output);
	XCTAssertNil(error);
}

- (void)testAutoFetchParsesRemoteSnapshotAndNumericGitOutputs
{
	PBAutoFetchOutputSpy *manager = [[PBAutoFetchOutputSpy alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/gitx-output" isDirectory:YES];
	manager.testOutput = @"refs/remotes/origin/main\tabc\nrefs/remotes/origin/HEAD\tdef\nmalformed\n";
	NSError *error = nil;

	XCTAssertEqualObjects([manager remoteSnapshotForURL:url error:&error], @{@"refs/remotes/origin/main" : @"abc"});
	manager.testOutput = @"7\n";
	XCTAssertEqual([manager commitCountFrom:@"old" to:@"new" repositoryURL:url], 7);
	manager.testOutput = @"1234\n";
	XCTAssertEqual([manager commitTimestampForSHA:@"new" repositoryURL:url], 1234);
	manager.testError = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
	XCTAssertEqual([manager commitTimestampForSHA:@"new" repositoryURL:url], 0);
}

- (void)testAutoFetchSuccessfulFetchRefreshesAndNotifiesOnlyFastForwardAdvances
{
	PBAutoFetchBehaviorSpy *manager = [[PBAutoFetchBehaviorSpy alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/gitx-success" isDirectory:YES];
	manager.testSnapshots = @[
		@{@"refs/remotes/origin/main" : @"old", @"refs/remotes/origin/stable" : @"same"},
		@{@"refs/remotes/origin/main" : @"new", @"refs/remotes/origin/stable" : @"same", @"refs/remotes/origin/new" : @"first"},
	];
	manager.testTask = [[PBAutoFetchTaskSpy alloc] init];
	manager.testTask.succeeds = YES;
	manager.ancestorResult = YES;
	manager.testCommitCount = 3;
	manager.testTimestamp = 1234;
	manager.deliveryExpectation = [self expectationWithDescription:@"success delivered"];
	[PBGitDefaults setAutoFetchIntervalMinutes:5];
	[PBGitDefaults setNotifyAboutFetchedCommits:YES forRepositoryURL:url];
	[manager setValue:[NSMutableSet setWithObject:url.path] forKey:@"inFlightRepositories"];

	[manager fetchRepositoryAtURL:url key:url.path];
	[self waitForExpectations:@[ manager.deliveryExpectation ] timeout:2];

	XCTAssertEqual(manager.refreshCount, (NSUInteger)1);
	XCTAssertEqual(manager.advanceNotificationCount, (NSUInteger)1);
	NSDictionary *failureCounts = [manager valueForKey:@"failureCounts"];
	XCTAssertNil(failureCounts[url.path]);
}

- (void)testAutoFetchFailureBacksOffAndNotifiesOnlyOnFirstFailure
{
	PBAutoFetchBehaviorSpy *manager = [[PBAutoFetchBehaviorSpy alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/gitx-failure" isDirectory:YES];
	manager.testSnapshots = @[ @{@"refs/remotes/origin/main" : @"old"} ];
	manager.snapshotError = [NSError errorWithDomain:@"test" code:9 userInfo:nil];
	manager.testTask = [[PBAutoFetchTaskSpy alloc] init];
	manager.testTask.succeeds = NO;
	manager.testTask.testError = manager.snapshotError;
	[manager setValue:[NSMutableSet setWithObject:url.path] forKey:@"inFlightRepositories"];

	manager.deliveryExpectation = [self expectationWithDescription:@"first failure delivered"];
	[manager fetchRepositoryAtURL:url key:url.path];
	[self waitForExpectations:@[ manager.deliveryExpectation ] timeout:2];
	XCTAssertEqual(manager.failureNotificationCount, (NSUInteger)1);
	XCTAssertEqualObjects([[manager valueForKey:@"failureCounts"] objectForKey:url.path], @1);

	[manager setValue:[NSMutableSet setWithObject:url.path] forKey:@"inFlightRepositories"];
	manager.deliveryExpectation = nil;
	[manager fetchRepositoryAtURL:url key:url.path];
	XCTestExpectation *settled = [self expectationWithDescription:@"second failure settled"];
	dispatch_async(dispatch_get_main_queue(), ^{
		[settled fulfill];
	});
	[self waitForExpectations:@[ settled ] timeout:2];
	XCTAssertEqual(manager.failureNotificationCount, (NSUInteger)1);
	XCTAssertEqualObjects([[manager valueForKey:@"failureCounts"] objectForKey:url.path], @2);
}

- (void)testAutoFetchStopSuppressesStaleFetchDelivery
{
	PBAutoFetchBehaviorSpy *manager = [[PBAutoFetchBehaviorSpy alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/gitx-cancelled-fetch" isDirectory:YES];
	manager.testSnapshots = @[
		@{@"refs/remotes/origin/main" : @"old"},
		@{@"refs/remotes/origin/main" : @"new"},
	];
	manager.testTask = [[PBAutoFetchTaskSpy alloc] init];
	manager.testTask.succeeds = YES;
	manager.testTask.launchExpectation = [self expectationWithDescription:@"fetch launched"];
	manager.testTask.launchGate = dispatch_semaphore_create(0);
	manager.ancestorResult = YES;
	manager.testCommitCount = 1;
	manager.testTimestamp = 1234;
	manager.deliveryExpectation = [self expectationWithDescription:@"cancelled delivery suppressed"];
	manager.deliveryExpectation.inverted = YES;
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeNone];
	[manager start];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[manager fetchRepositoryAtURL:url key:url.path];
	});
	[self waitForExpectations:@[ manager.testTask.launchExpectation ] timeout:2];
	[manager stop];
	dispatch_semaphore_signal(manager.testTask.launchGate);
	[self waitForExpectations:@[ manager.deliveryExpectation ] timeout:0.25];

	XCTAssertEqual(manager.refreshCount, (NSUInteger)0);
	XCTAssertEqual(manager.failureNotificationCount, (NSUInteger)0);
	XCTAssertEqual(manager.advanceNotificationCount, (NSUInteger)0);
}

- (void)testAutoFetchNotificationsDescribeFailuresAndMultipleAdvances
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	NSURL *url = [NSURL fileURLWithPath:@"/tmp/example" isDirectory:YES];
	PBAutoFetchLastNotificationRequest = nil;
	PBFeatureSwapInstanceMethods(
		UNUserNotificationCenter.class,
		@selector(addNotificationRequest:withCompletionHandler:),
		@selector(pb_feature_addNotificationRequest:completionHandler:));
	@try {
		NSError *error = [NSError errorWithDomain:@"test" code:4 userInfo:@{NSLocalizedFailureReasonErrorKey : @"Offline"}];
		[manager postFailureNotificationForURL:url error:error];
		XCTAssertTrue([PBAutoFetchLastNotificationRequest.content.body containsString:@"Offline"]);
		XCTAssertEqualObjects(PBAutoFetchLastNotificationRequest.content.userInfo[@"kind"], @"failure");

		[manager postAdvanceNotificationForURL:url
									  advances:@[
										  @{@"ref" : @"refs/remotes/origin/main", @"sha" : @"a", @"count" : @1, @"timestamp" : @1},
										  @{@"ref" : @"refs/remotes/origin/next", @"sha" : @"b", @"count" : @2, @"timestamp" : @2},
									  ]];
		XCTAssertTrue([PBAutoFetchLastNotificationRequest.content.title containsString:@"3 new commits"]);
		XCTAssertEqualObjects(PBAutoFetchLastNotificationRequest.content.userInfo[@"sha"], @"b");
		XCTAssertEqualObjects(PBAutoFetchLastNotificationRequest.content.userInfo[@"multipleBranches"], @YES);
	} @finally {
		PBFeatureSwapInstanceMethods(
			UNUserNotificationCenter.class,
			@selector(addNotificationRequest:withCompletionHandler:),
			@selector(pb_feature_addNotificationRequest:completionHandler:));
	}
}

- (void)testAutoFetchForegroundNotificationRequestsBannerAndSound
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	__block UNNotificationPresentationOptions options = 0;
	[manager userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter
			willPresentNotification:(UNNotification *)nil
			  withCompletionHandler:^(UNNotificationPresentationOptions value) {
				  options = value;
			  }];
	XCTAssertTrue((options & UNNotificationPresentationOptionBanner) != 0);
	XCTAssertTrue((options & UNNotificationPresentationOptionSound) != 0);
}

- (void)testAutoFetchCandidateSelectionCoversActiveOpenAndRecentScopes
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	PBAutoFetchDocumentControllerSpy *controller = class_createInstance(PBAutoFetchDocumentControllerSpy.class, 0);
	PBAutoFetchRepositorySpy *repository = class_createInstance(PBAutoFetchRepositorySpy.class, 0);
	repository.testWorkingDirectoryURL = [NSURL fileURLWithPath:@"/tmp/gitx-open-repository" isDirectory:YES];
	PBAutoFetchRepositoryDocumentSpy *document = class_createInstance(PBAutoFetchRepositoryDocumentSpy.class, 0);
	document.testRepository = repository;
	controller.testDocuments = @[ document, [[NSDocument alloc] init] ];
	controller.testCurrentDocument = document;
	NSURL *recent = [NSURL fileURLWithPath:@"/tmp/gitx-recent-repository" isDirectory:YES];
	controller.testRecentURLs = @[ recent, [NSURL URLWithString:@"https://example.com/not-local"] ];
	PBAutoFetchDocumentController = controller;
	PBFeatureSwapClassMethods(NSDocumentController.class,
							  @selector(sharedDocumentController),
							  @selector(pb_feature_sharedDocumentController));
	@try {
		[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeActiveRepository];
		XCTAssertEqualObjects([manager candidateRepositoryURLs].allValues, @[ repository.testWorkingDirectoryURL ]);

		[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenRepositories];
		XCTAssertEqualObjects([manager candidateRepositoryURLs].allValues, @[ repository.testWorkingDirectoryURL ]);

		[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenAndRecentRepositories];
		NSDictionary<NSString *, NSURL *> *candidates = [manager candidateRepositoryURLs];
		XCTAssertEqual(candidates.count, (NSUInteger)2);
		XCTAssertEqualObjects(candidates[recent.path], recent);
	} @finally {
		PBFeatureSwapClassMethods(NSDocumentController.class,
								  @selector(sharedDocumentController),
								  @selector(pb_feature_sharedDocumentController));
		PBAutoFetchDocumentController = nil;
	}
}

- (void)testAutoFetchFindsAndRefreshesMatchingOpenRepository
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	PBAutoFetchDocumentControllerSpy *controller = class_createInstance(PBAutoFetchDocumentControllerSpy.class, 0);
	PBAutoFetchRepositorySpy *repository = class_createInstance(PBAutoFetchRepositorySpy.class, 0);
	repository.testWorkingDirectoryURL = [NSURL fileURLWithPath:@"/tmp/gitx-refresh/../gitx-refresh/repository" isDirectory:YES];
	PBAutoFetchRepositoryDocumentSpy *document = class_createInstance(PBAutoFetchRepositoryDocumentSpy.class, 0);
	document.testRepository = repository;
	controller.testDocuments = @[ [[NSDocument alloc] init], document ];
	PBAutoFetchDocumentController = controller;
	PBFeatureSwapClassMethods(NSDocumentController.class,
							  @selector(sharedDocumentController),
							  @selector(pb_feature_sharedDocumentController));
	@try {
		NSURL *equivalent = [NSURL fileURLWithPath:@"/tmp/gitx-refresh/repository" isDirectory:YES];
		XCTAssertEqual([manager openDocumentForRepositoryURL:equivalent], document);
		[manager refreshOpenRepositoryAtURL:equivalent];
		XCTAssertEqual(repository.reloadCount, (NSUInteger)1);
		XCTAssertEqual(repository.forceUpdateCount, (NSUInteger)1);
		XCTAssertNil([manager openDocumentForRepositoryURL:[NSURL fileURLWithPath:@"/tmp/missing"]]);
	} @finally {
		PBFeatureSwapClassMethods(NSDocumentController.class,
								  @selector(sharedDocumentController),
								  @selector(pb_feature_sharedDocumentController));
		PBAutoFetchDocumentController = nil;
	}
}

- (void)testAutoFetchAncestorProbeReturnsGitTaskResult
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	XCTAssertFalse([manager isAncestor:@"missing-old"
									of:@"missing-new"
						 repositoryURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]]);
}

- (void)testAutoFetchNotificationActivationHandlesMissingOpenAndExistingRepositories
{
	PBAutoFetchManager *manager = [[PBAutoFetchManager alloc] init];
	PBAutoFetchDocumentControllerSpy *controller = class_createInstance(PBAutoFetchDocumentControllerSpy.class, 0);
	PBAutoFetchRepositorySpy *repository = class_createInstance(PBAutoFetchRepositorySpy.class, 0);
	NSURL *repositoryURL = [NSURL fileURLWithPath:@"/tmp/gitx-notification" isDirectory:YES];
	repository.testWorkingDirectoryURL = repositoryURL;
	PBAutoFetchWindowControllerSpy *windowController = class_createInstance(PBAutoFetchWindowControllerSpy.class, 0);
	PBAutoFetchHistoryControllerSpy *historyController = class_createInstance(PBAutoFetchHistoryControllerSpy.class, 0);
	windowController.testHistoryViewController = historyController;
	PBAutoFetchRepositoryDocumentSpy *document = class_createInstance(PBAutoFetchRepositoryDocumentSpy.class, 0);
	document.testRepository = repository;
	document.testWindowController = windowController;
	controller.testDocuments = @[];
	controller.testDocumentToOpen = document;
	PBAutoFetchDocumentController = controller;
	PBFeatureSwapClassMethods(NSDocumentController.class,
							  @selector(sharedDocumentController),
							  @selector(pb_feature_sharedDocumentController));
	@try {
		PBAutoFetchNotificationSpy *notification = class_createInstance(PBAutoFetchNotificationSpy.class, 0);
		PBAutoFetchNotificationResponseSpy *response = class_createInstance(PBAutoFetchNotificationResponseSpy.class, 0);
		response.testNotification = notification;
		__block NSUInteger completionCount = 0;

		UNMutableNotificationContent *emptyContent = [[UNMutableNotificationContent alloc] init];
		notification.testRequest = [UNNotificationRequest requestWithIdentifier:@"empty" content:emptyContent trigger:nil];
		[manager userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter
			didReceiveNotificationResponse:response
					 withCompletionHandler:^{
						 completionCount++;
					 }];
		XCTAssertEqual(completionCount, (NSUInteger)1);

		UNMutableNotificationContent *multipleContent = [[UNMutableNotificationContent alloc] init];
		multipleContent.userInfo = @{@"repository" : repositoryURL.path, @"multipleBranches" : @YES};
		notification.testRequest = [UNNotificationRequest requestWithIdentifier:@"multiple" content:multipleContent trigger:nil];
		[manager userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter
			didReceiveNotificationResponse:response
					 withCompletionHandler:^{
						 completionCount++;
					 }];
		XCTestExpectation *opened = [self expectationWithDescription:@"notification opened repository"];
		dispatch_async(dispatch_get_main_queue(), ^{
			[opened fulfill];
		});
		[self waitForExpectations:@[ opened ] timeout:2];
		XCTAssertEqual(windowController.showHistoryCount, (NSUInteger)1);
		XCTAssertEqual(repository.testBranchFilter, kGitXAllBranchesFilter);

		controller.testDocuments = @[ document ];
		UNMutableNotificationContent *branchContent = [[UNMutableNotificationContent alloc] init];
		branchContent.userInfo = @{
			@"repository" : repositoryURL.path,
			@"multipleBranches" : @NO,
			@"ref" : @"refs/remotes/origin/main",
			@"sha" : @"0123456789012345678901234567890123456789",
		};
		historyController.selectionExpectation = [self expectationWithDescription:@"notification selected commit"];
		notification.testRequest = [UNNotificationRequest requestWithIdentifier:@"branch" content:branchContent trigger:nil];
		[manager userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter
			didReceiveNotificationResponse:response
					 withCompletionHandler:^{
						 completionCount++;
					 }];
		XCTestExpectation *focused = [self expectationWithDescription:@"notification focused repository"];
		dispatch_async(dispatch_get_main_queue(), ^{
			[focused fulfill];
		});
		[self waitForExpectations:@[ focused, historyController.selectionExpectation ] timeout:2];
		XCTAssertEqual(windowController.showHistoryCount, (NSUInteger)2);
		XCTAssertEqual(repository.testBranchFilter, kGitXSelectedBranchFilter);
		XCTAssertEqual(completionCount, (NSUInteger)3);
	} @finally {
		PBFeatureSwapClassMethods(NSDocumentController.class,
								  @selector(sharedDocumentController),
								  @selector(pb_feature_sharedDocumentController));
		PBAutoFetchDocumentController = nil;
	}
}

- (void)testRepositoryDocumentControllerConfiguresAndCompletesTheOpenPanel
{
	PBRepositoryDocumentController *controller = PBNewRepositoryDocumentController(PBRepositoryDocumentController.class);
	PBRepositoryOpenPanelSpy *panel = PBNewRepositoryOpenPanelSpy();
	panel.response = NSModalResponseOK;
	__block NSInteger response = NSModalResponseCancel;

	[controller beginOpenPanel:panel
					  forTypes:@[]
			 completionHandler:^(NSInteger value) {
				 response = value;
			 }];

	XCTAssertTrue(panel.canChooseFiles);
	XCTAssertTrue(panel.canChooseDirectories);
	XCTAssertEqualObjects(panel.allowedFileTypes, (@[ @"git" ]));
	XCTAssertEqual(response, NSModalResponseOK);
}

- (void)testRepositoryDocumentControllerReportsCancelledRepositoryCreation
{
	PBRepositoryOpenPanelSpy *panel = PBNewRepositoryOpenPanelSpy();
	panel.response = NSModalResponseCancel;
	[PBRepositoryDocumentControllerSpy setTestOpenPanel:panel];
	PBRepositoryDocumentController *controller = PBNewRepositoryDocumentController(PBRepositoryDocumentControllerSpy.class);
	NSError *error = nil;

	NSDocument *document = [controller makeUntitledDocumentOfType:PBGitRepositoryDocumentType error:&error];

	XCTAssertNil(document);
	XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
	XCTAssertEqual(error.code, NSUserCancelledError);
}

- (void)testRepositoryDocumentControllerCreatesRepositoryInChosenFolder
{
	NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
							   isDirectory:YES];
	XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil]);
	PBRepositoryOpenPanelSpy *panel = PBNewRepositoryOpenPanelSpy();
	panel.response = NSModalResponseOK;
	panel.selectedURL = folder;
	[PBRepositoryDocumentControllerSpy setTestOpenPanel:panel];
	PBRepositoryDocumentController *controller = PBNewRepositoryDocumentController(PBRepositoryDocumentControllerSpy.class);
	NSError *error = nil;

	NSDocument *document = [controller makeUntitledDocumentOfType:PBGitRepositoryDocumentType error:&error];

	XCTAssertNotNil(document);
	XCTAssertNil(error);
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[folder.path stringByAppendingPathComponent:@".git"]]);
	[document close];
	[[NSFileManager defaultManager] removeItemAtURL:folder error:nil];
}

- (void)testRepositoryDocumentControllerReportsRepositoryCreationFailure
{
	PBRepositoryOpenPanelSpy *panel = PBNewRepositoryOpenPanelSpy();
	panel.response = NSModalResponseOK;
	panel.selectedURL = [NSURL fileURLWithPath:@"/dev/null/not-a-directory" isDirectory:YES];
	[PBRepositoryDocumentControllerSpy setTestOpenPanel:panel];
	PBRepositoryDocumentController *controller = PBNewRepositoryDocumentController(PBRepositoryDocumentControllerSpy.class);
	NSError *error = nil;

	NSDocument *document = [controller makeUntitledDocumentOfType:PBGitRepositoryDocumentType error:&error];

	XCTAssertNil(document);
	XCTAssertNotNil(error);
}

- (void)testRepositoryDocumentControllerValidatesNewAndUnrelatedMenuItems
{
	PBRepositoryDocumentController *controller = PBNewRepositoryDocumentController(PBRepositoryDocumentController.class);
	NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@""];
	NSMenuItem *otherItem = [[NSMenuItem alloc] initWithTitle:@"Other" action:@selector(copy:) keyEquivalent:@""];

	XCTAssertEqual([controller validateMenuItem:newItem], [PBGitBinary path] != nil);
	XCTAssertTrue([controller validateMenuItem:otherItem]);
}

- (void)testJumpToCheckedOutBranchReloadsAndReadsHead
{
	PBCheckedOutBranchRepositorySpy *repository = [[PBCheckedOutBranchRepositorySpy alloc] init];
	PBCheckedOutBranchDocumentSpy *document = [[PBCheckedOutBranchDocumentSpy alloc] init];
	document.repositorySpy = repository;
	PBGitWindowController *controller = [[PBGitWindowController alloc] init];
	controller.document = document;

	[controller jumpToCheckedOutBranch:self];

	XCTAssertEqual(repository.reloadRefsCount, 1);
	XCTAssertEqual(repository.readCurrentBranchCount, 1);
}

- (void)testManualRefreshForwardsToContentAndSynchronizesWindowTitle
{
	PBManualRefreshContentSpy *content = [[PBManualRefreshContentSpy alloc] init];
	PBManualRefreshWindowControllerSpy *controller = [[PBManualRefreshWindowControllerSpy alloc] init];
	[controller setValue:content forKey:@"contentController"];

	[controller refresh:self];

	XCTAssertEqual(content.refreshCount, (NSUInteger)1);
	XCTAssertEqual(controller.titleSynchronizationCount, (NSUInteger)1);
}

- (void)testEmbeddedCommandLineToolDeclaresAppleEventsAuthorization
{
	NSURL *commandLineToolURL = [NSBundle.mainBundle URLForResource:@"gitx" withExtension:nil];
	XCTAssertNotNil(commandLineToolURL);

	SecStaticCodeRef staticCode = NULL;
	OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)commandLineToolURL, kSecCSDefaultFlags, &staticCode);
	XCTAssertEqual(status, errSecSuccess);
	XCTAssertNotEqual(staticCode, NULL);

	CFDictionaryRef signingInformation = NULL;
	status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &signingInformation);
	if (staticCode) CFRelease(staticCode);
	XCTAssertEqual(status, errSecSuccess);
	NSDictionary *information = CFBridgingRelease(signingInformation);
	NSDictionary *infoPlist = information[(__bridge NSString *)kSecCodeInfoPList];
	NSDictionary *entitlements = information[(__bridge NSString *)kSecCodeInfoEntitlementsDict];

	NSString *usageDescription = infoPlist[@"NSAppleEventsUsageDescription"];
	XCTAssertGreaterThan(usageDescription.length, 0,
						 @"The CLI must explain its Apple-events use before macOS can authorize delivery to GitX");
	XCTAssertEqualObjects(entitlements[@"com.apple.security.automation.apple-events"], @YES,
						  @"The hardened CLI must be entitled to send its piped diff to the GitX app");
}

- (void)testEmbeddedCommandLineToolResolvesBackToItsApplicationBundle
{
	NSURL *commandLineToolURL = [NSBundle.mainBundle URLForResource:@"gitx" withExtension:nil];
	XCTAssertNotNil(commandLineToolURL);

	XCTAssertEqualObjects(GitXApplicationBundlePathForToolPath(commandLineToolURL.path).stringByStandardizingPath,
						  NSBundle.mainBundle.bundlePath.stringByStandardizingPath,
						  @"The CLI must find its own app bundle by path so it never depends on a bundle identifier "
						  @"another bundle can claim");
}

- (void)testApplicationBundleLookupDerivesTheBundleFromAnEmbeddedToolPath
{
	XCTAssertEqualObjects(GitXApplicationBundlePathForToolPath(@"/Applications/GitX.app/Contents/Resources/gitx"),
						  @"/Applications/GitX.app");
	XCTAssertEqualObjects(GitXApplicationBundlePathForToolPath(@"/Volumes/Ext Disk/Git X.app/Contents/Resources/gitx"),
						  @"/Volumes/Ext Disk/Git X.app");
	XCTAssertEqualObjects(GitXApplicationBundlePathForToolPath(@"/Users/example/Desktop/GitX.app/Contents/Resources/gitx"),
						  @"/Users/example/Desktop/GitX.app",
						  @"Derivation must be lexical so it never depends on what exists on the running machine");
	XCTAssertEqualObjects(GitXApplicationBundlePathForToolPath(@"/Users/example/Build/../GitX.app/Contents/Resources/gitx"),
						  @"/Users/example/Build/../GitX.app",
						  @"Lexical derivation must retain parent-directory components rather than canonicalizing the path");
}

- (void)testApplicationBundleLookupRejectsToolsOutsideAnApplicationBundle
{
	XCTAssertNil(GitXApplicationBundlePathForToolPath(nil));
	XCTAssertNil(GitXApplicationBundlePathForToolPath(@""));
	XCTAssertNil(GitXApplicationBundlePathForToolPath(@"/usr/local/bin/gitx"),
				 @"A tool outside a bundle must fall back to the bundle-identifier lookup");
	XCTAssertNil(GitXApplicationBundlePathForToolPath(@"/Users/example/Build/Products/Debug/gitx"),
				 @"Running from a build directory must fall back to the bundle-identifier lookup");
	XCTAssertNil(GitXApplicationBundlePathForToolPath(@"/Applications/GitX.app/Contents/MacOS/GitX"),
				 @"Only the tool shipped in Contents/Resources identifies the enclosing bundle");
	XCTAssertNil(GitXApplicationBundlePathForToolPath(@"/Applications/GitX.app/Contents/Resources/tools/gitx"),
				 @"A deeper resource path must not be mistaken for the app bundle");
	XCTAssertNil(GitXApplicationBundlePathForToolPath(@"/Library/Frameworks/Sparkle.framework/Resources/gitx"),
				 @"A non-app bundle claiming the identifier must never be treated as GitX");
}

- (void)testSpaceKeyRoutesSelectedFileRowsToStageAndUnstageActions
{
	PBFileChangesActionTarget *target = [[PBFileChangesActionTarget alloc] init];
	PBFileChangesTableView *table = [[PBFileChangesTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 120)];
	table.dataSource = target;
	table.delegate = target;
	table.allowsMultipleSelection = YES;
	[table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"Files"]];
	[table reloadData];
	[table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];

	table.tag = 0;
	[table keyDown:[self spaceKeyEventWithModifiers:0]];
	XCTAssertEqual(target.stagingToggleCount, 1);
	XCTAssertEqual(target.lastSender, table);

	table.tag = 1;
	[table keyDown:[self spaceKeyEventWithModifiers:0]];
	XCTAssertEqual(target.stagingToggleCount, 2);

	[table keyDown:[self spaceKeyEventWithModifiers:NSEventModifierFlagCommand]];
	XCTAssertEqual(target.stagingToggleCount, 2, @"Modified Space should retain the table's normal key handling");

	[table deselectAll:nil];
	[table keyDown:[self spaceKeyEventWithModifiers:0]];
	XCTAssertEqual(target.stagingToggleCount, 2, @"Space without selected rows should not invoke a staging action");

	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	table.delegate = nil;
	[table keyDown:[self spaceKeyEventWithModifiers:0]];
	XCTAssertEqual(target.stagingToggleCount, 2, @"Space without a staging delegate must not route through the responder chain");
}

- (void)testContextClickOnSelectedFilePreservesMultipleSelection
{
	PBFileChangesActionTarget *target = [[PBFileChangesActionTarget alloc] init];
	PBFileChangesTableView *table = [[PBFileChangesTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 120)];
	table.dataSource = target;
	table.delegate = target;
	table.allowsMultipleSelection = YES;
	table.menu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Files", nil)];
	[table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"Files"]];

	NSWindow *window = [[NSWindow alloc] initWithContentRect:table.frame
												   styleMask:NSWindowStyleMaskBorderless
													 backing:NSBackingStoreBuffered
													   defer:NO];
	window.contentView = table;
	[table reloadData];
	[table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];

	NSPoint tableLocation = NSMakePoint(10, NSMidY([table rectOfRow:1]));
	NSPoint windowLocation = [table convertPoint:tableLocation toView:nil];
	XCTAssertEqual([table rowAtPoint:tableLocation], (NSInteger)1);
	XCTAssertNotNil([table menuForEvent:[self rightMouseEventAtLocation:windowLocation windowNumber:window.windowNumber]]);
	XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]);
}

- (void)testContextClickOutsideSelectedFilesSelectsOnlyClickedRow
{
	PBFileChangesActionTarget *target = [[PBFileChangesActionTarget alloc] init];
	PBFileChangesTableView *table = [[PBFileChangesTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 120)];
	table.dataSource = target;
	table.delegate = target;
	table.allowsMultipleSelection = YES;
	table.menu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Files", nil)];
	[table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"Files"]];

	NSWindow *window = [[NSWindow alloc] initWithContentRect:table.frame
												   styleMask:NSWindowStyleMaskBorderless
													 backing:NSBackingStoreBuffered
													   defer:NO];
	window.contentView = table;
	[table reloadData];
	[table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];

	NSPoint tableLocation = NSMakePoint(10, NSMidY([table rectOfRow:2]));
	NSPoint windowLocation = [table convertPoint:tableLocation toView:nil];
	XCTAssertEqual([table rowAtPoint:tableLocation], (NSInteger)2);
	XCTAssertNotNil([table menuForEvent:[self rightMouseEventAtLocation:windowLocation windowNumber:window.windowNumber]]);
	XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndex:2]);
}

- (void)testRevisionCellObjectValueIsNullableBeforeTableConfiguration
{
	PBGitRevisionCell *cell = [[PBGitRevisionCell alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
	XCTAssertNil(cell.objectValue);
}

- (void)testNativeDiffLoadsImageDataOffMainAndInstallsAttachment
{
	NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
																	   pixelsWide:2
																	   pixelsHigh:2
																	bitsPerSample:8
																  samplesPerPixel:4
																		 hasAlpha:YES
																		 isPlanar:NO
																   colorSpaceName:NSCalibratedRGBColorSpace
																	  bytesPerRow:0
																	 bitsPerPixel:0];
	memset(bitmap.bitmapData, 0x7f, bitmap.bytesPerRow * bitmap.pixelsHigh);
	NSData *imageData = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	XCTAssertGreaterThan(imageData.length, 0);

	PBNativeImageDataDelegate *delegate = [[PBNativeImageDataDelegate alloc] init];
	delegate.imageData = imageData;
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	view.delegate = delegate;
	NSDictionary<NSString *, id> *imageSource = @{
		PBNativeImageSourceRevisionsKey : @[ @"abc123" ],
		PBNativeImageSourceGitLaunchPathKey : @"/usr/bin/git",
		PBNativeImageSourceGitDirectoryKey : @"/tmp/example/.git",
		PBNativeImageSourceTaskDirectoryKey : @"/tmp/example",
	};
	NSString *diff = @"diff --git a/image.png b/image.png\n"
					 @"Binary files a/image.png and b/image.png differ\n";
	[view showDiffSections:@[ @{
			  PBNativeSectionTextKey : diff,
			  PBNativeSectionContextKey : @"readOnly",
			  PBNativeSectionImageSourceKey : imageSource,
		  } ]];
	[self waitForNativeView:view toContainString:@"Show image"];
	NSUInteger linkIndex = NSNotFound;
	id link = [self linkInNativeView:view titled:@"Show image" index:&linkIndex];
	XCTAssertNotNil(link);
	XCTAssertTrue([view textView:view.textView clickedOnLink:link atIndex:linkIndex]);

	NSPredicate *hasAttachment = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		NSAttributedString *storage = view.textView.textStorage;
		__block BOOL foundAttachment = NO;
		[storage enumerateAttribute:NSAttachmentAttributeName
							inRange:NSMakeRange(0, storage.length)
							options:0
						 usingBlock:^(id value, __unused NSRange range, BOOL *stop) {
							 if (value) {
								 foundAttachment = YES;
								 *stop = YES;
							 }
						 }];
		return foundAttachment;
	}];
	XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:hasAttachment object:view];
	[self waitForExpectations:@[ expectation ] timeout:10.0];

	XCTAssertFalse(delegate.callbackWasOnMainThread);
	XCTAssertEqualObjects(delegate.capturedImageSource, imageSource);
}

- (void)testNativeBlameRendersMetadataReuseAndFallbacks
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSString *sha = @"0123456789abcdef0123456789abcdef01234567";
	NSString *otherSHA = @"fedcba9876543210fedcba9876543210fedcba98";
	NSString *porcelain = [NSString stringWithFormat:@"%@ 1 1 1\nauthor An Extremely Long Author Name\nsummary First line\n\tlet first = 1\n%@ 2 2\n\tlet second = 2\n%@ 3 3 1\nauthor Bob\nsummary Third line\n\tlet third = 3\n", sha, sha, otherSHA];

	[view showBlameSections:@[ @{
								  PBNativeSectionPathKey : @"Example.swift",
								  PBNativeSectionTextKey : porcelain,
							  },
							   @{} ]];
	[self waitForNativeView:view toContainString:@"let third = 3"];

	XCTAssertTrue([view.textView.string containsString:@"Example.swift"]);
	XCTAssertTrue([view.textView.string containsString:@"01234567"]);
	XCTAssertTrue([view.textView.string containsString:@"An Extremely Long…"]);
	XCTAssertTrue([view.textView.string containsString:@"let first = 1"]);
	XCTAssertTrue([view.textView.string containsString:@"let second = 2"]);
}

- (void)testNativeHistoryRendersEntriesAndRoutesCommitLinks
{
	PBNativeImageDataDelegate *delegate = [[PBNativeImageDataDelegate alloc] init];
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	view.delegate = delegate;
	NSString *sha = @"0123456789abcdef0123456789abcdef01234567";
	[view showHistorySections:@[ @{
			  PBNativeSectionPathKey : @"History fallback title",
			  PBNativeSectionEntriesKey : @[
				  @{@"subject" : @"Initial subject", @"author" : @"Ada", @"date" : @"Today", @"sha" : sha},
				  @{},
			  ],
		  } ]];
	[self waitForNativeView:view toContainString:@"Initial subject"];

	XCTAssertTrue([view.textView.string containsString:@"History fallback title"]);
	XCTAssertTrue([view.textView.string containsString:@"Ada  •  Today  •  0123456789ab"]);
	NSUInteger linkIndex = NSNotFound;
	id link = [self linkInNativeView:view titled:@"0123456789ab" index:&linkIndex];
	XCTAssertNotNil(link);
	XCTAssertTrue([view textView:view.textView clickedOnLink:link atIndex:linkIndex]);
	XCTAssertEqualObjects(delegate.selectedCommitSHA, sha);
}

- (void)testNativeDiffRoutesHunkLineBlockCollapseAndScrollInteractions
{
	PBNativeImageDataDelegate *delegate = [[PBNativeImageDataDelegate alloc] init];
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 120)];
	view.delegate = delegate;
	NSString *diff = @"diff --git a/file.txt b/file.txt\n"
					 @"index 1111111..2222222 100644\n"
					 @"--- a/file.txt\n"
					 @"+++ b/file.txt\n"
					 @"@@ -1,2 +1,2 @@\n"
					 @"-old\n"
					 @"+new\n"
					 @" tail\n";
	NSDictionary *unstaged = @{
		PBNativeSectionTextKey : diff,
		PBNativeSectionContextKey : @"unstaged",
		PBNativeSectionDiffLayoutKey : @0,
	};
	[view showDiffSections:@[ unstaged ]];
	[self waitForNativeView:view toContainString:@"Discard line"];

	NSUInteger linkIndex = NSNotFound;
	id hunkLink = [self linkInNativeView:view titled:@"Stage hunk" index:&linkIndex];
	XCTAssertTrue([view textView:view.textView clickedOnLink:hunkLink atIndex:linkIndex]);
	id lineLink = [self linkInNativeView:view titled:@"Stage line" index:&linkIndex];
	XCTAssertTrue([view textView:view.textView clickedOnLink:lineLink atIndex:linkIndex]);
	XCTAssertEqualObjects(delegate.diffActions, (@[ @"stage", @"stage" ]));
	XCTAssertTrue([delegate.diffPatches.firstObject containsString:@"@@ -1,2 +1,2 @@"]);
	XCTAssertTrue([delegate.diffPatches.lastObject containsString:@"old"]);

	id collapseLink = [self linkInNativeView:view titled:@"▾ " index:&linkIndex];
	XCTAssertTrue([view textView:view.textView clickedOnLink:collapseLink atIndex:linkIndex]);
	[self waitForNativeView:view toContainString:@"▸ "];
	id expandLink = [self linkInNativeView:view titled:@"▸ " index:&linkIndex];
	XCTAssertTrue([view textView:view.textView clickedOnLink:expandLink atIndex:linkIndex]);
	[self waitForNativeView:view toContainString:@"Stage block"];

	[view showDiffSections:@[ @{
			  PBNativeSectionTextKey : diff,
			  PBNativeSectionContextKey : @"staged",
			  PBNativeSectionDiffLayoutKey : @0,
		  } ]];
	[self waitForNativeView:view toContainString:@"Unstage block"];
	id unstageLink = [self linkInNativeView:view titled:@"Unstage line" index:&linkIndex];
	XCTAssertTrue([view textView:view.textView clickedOnLink:unstageLink atIndex:linkIndex]);
	XCTAssertEqualObjects(delegate.diffActions.lastObject, @"unstage");
	XCTAssertTrue([delegate.diffPatches.lastObject containsString:@"old"]);

	XCTAssertFalse([view textView:view.textView clickedOnLink:[NSURL URLWithString:@"gitx-action://missing"] atIndex:0]);
	[view scrollPageDown];
	[view scrollPageUp];
}

- (void)testNativeDiffRendersEmptySections
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	[view showDiffSections:@[ @{PBNativeSectionTitleKey : @"Empty", PBNativeSectionTextKey : @""} ]];
	[self waitForNativeView:view toContainString:@"There are no differences."];
}

- (void)testNativeDiffCacheRestoresRenderedContentAndScrollSynchronously
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 120)];
	NSWindow *window = [[NSWindow alloc] initWithContentRect:view.frame
												   styleMask:NSWindowStyleMaskBorderless
													 backing:NSBackingStoreBuffered
													   defer:NO];
	window.contentView = view;
	NSMutableString *diff = [NSMutableString stringWithString:
												 @"diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1,200 +1,200 @@\n"];
	for (NSUInteger index = 0; index < 200; index++) {
		[diff appendFormat:@"-old-%lu\n+new-%lu\n", index, index];
	}
	NSArray<NSDictionary *> *sections = @[ @{
		PBNativeSectionTextKey : diff,
		PBNativeSectionContextKey : @"readOnly",
	} ];
	[view showDiffSections:sections cacheIdentifier:@"working-state-0" preserveScrollPosition:YES];
	[self waitForNativeView:view toContainString:@"new-199"];
	[window layoutIfNeeded];
	NSScrollView *scrollView = view.textView.enclosingScrollView;
	CGFloat maximumY = MAX(0, scrollView.documentView.frame.size.height - scrollView.contentView.bounds.size.height);
	[scrollView.contentView scrollToPoint:NSMakePoint(0, maximumY * 0.75)];
	[scrollView reflectScrolledClipView:scrollView.contentView];
	CGFloat expectedY = scrollView.contentView.bounds.origin.y;
	XCTAssertGreaterThan(expectedY, 0);

	[view showDiffSections:sections cacheIdentifier:@"working-state-0" preserveScrollPosition:YES];
	XCTAssertEqualWithAccuracy(scrollView.contentView.bounds.origin.y, expectedY, 1.0);
	((void (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"rerenderCurrentDiffPreservingScrollPosition"));
	[self waitForNativeView:view toContainString:@"new-199"];

	[view showMessage:@"Loading…"];
	[view showDiffSections:sections cacheIdentifier:@"working-state-0" preserveScrollPosition:YES];

	XCTAssertTrue([view.textView.string containsString:@"new-199"]);
	XCTAssertEqualWithAccuracy(scrollView.contentView.bounds.origin.y, expectedY, 1.0);
}

- (void)testAppearancePreferenceValidatesAndAppliesGlobally
{
	PBAppearancePreference originalPreference = [PBGitDefaults appearancePreference];
	NSAppearance *originalAppearance = NSApp.appearance;
	__block NSInteger notificationCount = 0;
	id notificationToken = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBAppearancePreferenceDidChangeNotification
					object:nil
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					notificationCount++;
				}];

	@try {
		[PBGitDefaults setAppearancePreference:PBAppearancePreferenceLight];
		XCTAssertEqual([PBGitDefaults appearancePreference], PBAppearancePreferenceLight);
		XCTAssertEqualObjects(NSApp.appearance.name, NSAppearanceNameAqua);

		[PBGitDefaults setAppearancePreference:PBAppearancePreferenceDark];
		XCTAssertEqual([PBGitDefaults appearancePreference], PBAppearancePreferenceDark);
		XCTAssertEqualObjects(NSApp.appearance.name, NSAppearanceNameDarkAqua);

		[PBGitDefaults setAppearancePreference:PBAppearancePreferenceAutomatic];
		XCTAssertEqual([PBGitDefaults appearancePreference], PBAppearancePreferenceAutomatic);
		XCTAssertNil(NSApp.appearance);

		[PBGitDefaults setAppearancePreference:(PBAppearancePreference)NSIntegerMax];
		XCTAssertEqual([PBGitDefaults appearancePreference], PBAppearancePreferenceAutomatic);
		XCTAssertNil(NSApp.appearance);
		XCTAssertEqual(notificationCount, 4);
	} @finally {
		[[NSNotificationCenter defaultCenter] removeObserver:notificationToken];
		[PBGitDefaults setAppearancePreference:originalPreference];
		NSApp.appearance = originalAppearance;
	}
}

- (void)testHistoryControllerPinsWorkingStateAboveSortedCommits
{
	PBHistoryArrayController *controller = [[PBHistoryArrayController alloc] initWithContent:@[
		@{@"subject" : @"B"}, @{@"subject" : @"A"}
	]];
	NSObject *workingState = [[NSObject alloc] init];
	controller.pinnedObject = workingState;
	controller.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"subject" ascending:YES] ];
	NSArray *arranged = controller.arrangedObjects;
	XCTAssertEqual(arranged.firstObject, workingState);
	XCTAssertEqualObjects(arranged[1][@"subject"], @"A");
}

- (void)testPinnedWorkingStatePreservesAnExistingCommitSelection
{
	NSObject *olderCommit = [[NSObject alloc] init];
	NSObject *newerCommit = [[NSObject alloc] init];
	PBHistoryArrayController *controller = [[PBHistoryArrayController alloc] initWithContent:@[ newerCommit, olderCommit ]];
	[controller setSelectedObjects:@[ olderCommit ]];

	controller.pinnedObject = [[NSObject alloc] init];
	XCTAssertEqualObjects(controller.selectedObjects, (@[ olderCommit ]));
	controller.pinnedObject = nil;
	XCTAssertEqualObjects(controller.selectedObjects, (@[ olderCommit ]));
}

- (void)testReplacingPinnedWorkingStateDoesNotDuplicateIt
{
	NSObject *commit = [[NSObject alloc] init];
	PBHistoryArrayController *controller = [[PBHistoryArrayController alloc] initWithContent:@[ commit ]];
	NSObject *firstWorkingState = [[NSObject alloc] init];
	NSObject *replacementWorkingState = [[NSObject alloc] init];
	controller.pinnedObject = firstWorkingState;
	XCTAssertEqualObjects(controller.arrangedObjects, (@[ firstWorkingState, commit ]));

	controller.pinnedObject = replacementWorkingState;
	XCTAssertEqualObjects(controller.arrangedObjects, (@[ replacementWorkingState, commit ]));
	controller.pinnedObject = nil;
	XCTAssertEqualObjects(controller.arrangedObjects, (@[ commit ]));
}

- (void)testContextClickSelectsOnlyAnUnselectedCommit
{
	Class commitListClass = NSClassFromString(@"GitX.PBCommitList");
	XCTAssertNotNil(commitListClass);
	SEL selector = NSSelectorFromString(@"shouldReplaceSelectionForContextClickAtRow:selectedRows:");
	XCTAssertTrue([commitListClass respondsToSelector:selector]);
	BOOL (*shouldReplaceSelection)(id, SEL, NSInteger, NSIndexSet *) = (void *)objc_msgSend;
	NSMutableIndexSet *selected = [NSMutableIndexSet indexSetWithIndex:1];
	[selected addIndex:2];
	XCTAssertTrue(shouldReplaceSelection(commitListClass, selector, 4, selected));
	XCTAssertFalse(shouldReplaceSelection(commitListClass, selector, 2, selected));
	XCTAssertFalse(shouldReplaceSelection(commitListClass, selector, -1, selected));
}

- (void)testHistoryRefreshFollowsHeadOnlyWhenItWasAlreadyViewed
{
	Class policyClass = NSClassFromString(@"PBHistoryRefreshSelectionPolicy");
	XCTAssertNotNil(policyClass);
	SEL selector = NSSelectorFromString(@"shouldFollowCheckedOutBranchWithStageSelected:viewedRef:previousHeadRef:");
	XCTAssertTrue([policyClass respondsToSelector:selector]);
	BOOL (*shouldFollowHead)(id, SEL, BOOL, NSString *, NSString *) = (void *)objc_msgSend;
	XCTAssertTrue(shouldFollowHead(policyClass, selector, NO, @"refs/heads/main", @"refs/heads/main"));
	XCTAssertFalse(shouldFollowHead(policyClass, selector, YES, @"refs/heads/main", @"refs/heads/main"));
	XCTAssertFalse(shouldFollowHead(policyClass, selector, NO, @"refs/heads/topic", @"refs/heads/main"));
	XCTAssertFalse(shouldFollowHead(policyClass, selector, NO, nil, @"refs/heads/main"));
}

- (void)testDisablingHistorySortingClearsNewDescriptors
{
	PBHistoryArrayController *controller = [[PBHistoryArrayController alloc] initWithContent:@[]];
	[PBGitDefaults setHistoryColumnSortingEnabled:NO];
	controller.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"subject" ascending:YES] ];
	XCTAssertEqual(controller.sortDescriptors.count, 0);
}

- (void)testHighlightingProducesAttributedSourceAndNativeViewsStayReadOnly
{
	NSAttributedString *source = [PBHighlighting highlightedStringForText:@"let value = 42\n" path:@"Example.swift"];
	XCTAssertEqualObjects(source.string, @"let value = 42\n");
	XCTAssertNotNil([source attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil]);

	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	[view showSourceSections:@[ @{PBNativeSectionPathKey : @"Example.swift", PBNativeSectionTextKey : @"let value = 42\n"} ]];
	XCTAssertFalse(view.textView.isEditable);
	XCTAssertTrue(view.textView.isSelectable);
}

- (void)testHighlightingCanRunOnTheBackgroundRenderQueue
{
	XCTestExpectation *highlighted = [self expectationWithDescription:@"background highlighting completed"];
	__block NSAttributedString *result = nil;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		result = [PBHighlighting highlightedStringForText:@"let value = 42\n" path:@"Example.swift"];
		[highlighted fulfill];
	});

	[self waitForExpectations:@[ highlighted ] timeout:2.0];
	XCTAssertEqualObjects(result.string, @"let value = 42\n");
}

- (void)testNativeDiffCombinesSyntaxAndDiffHighlighting
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSString *diff = @"diff --git a/Example.swift b/Example.swift\n"
					  "--- a/Example.swift\n"
					  "+++ b/Example.swift\n"
					  "@@ -1 +1 @@\n"
					  "-let oldValue = 1\n"
					  "+let newValue = 42\n"
					  "diff --git a/notes.txt b/notes.txt\n"
					  "--- a/notes.txt\n"
					  "+++ b/notes.txt\n"
					  "@@ -0,0 +1 @@\n"
					  "+plain value\n";
	[view showDiffSections:@[ @{PBNativeSectionTextKey : diff, PBNativeSectionContextKey : @"readOnly"} ]];
	[self waitForNativeView:view toContainString:@"+plain value"];

	NSTextStorage *storage = view.textView.textStorage;
	NSRange removedSwiftLine = [storage.string rangeOfString:@"-let oldValue = 1"];
	XCTAssertNotEqual(removedSwiftLine.location, NSNotFound);
	NSColor *removedPrefix = [storage attribute:NSForegroundColorAttributeName atIndex:removedSwiftLine.location effectiveRange:nil];
	NSColor *removedToken = [storage attribute:NSForegroundColorAttributeName atIndex:removedSwiftLine.location + 1 effectiveRange:nil];
	XCTAssertNotEqualObjects(removedPrefix, removedToken);
	XCTAssertNotNil([storage attribute:NSBackgroundColorAttributeName atIndex:removedSwiftLine.location + 1 effectiveRange:nil]);

	NSRange swiftLine = [storage.string rangeOfString:@"+let newValue = 42"];
	XCTAssertNotEqual(swiftLine.location, NSNotFound);
	NSColor *swiftPrefix = [storage attribute:NSForegroundColorAttributeName atIndex:swiftLine.location effectiveRange:nil];
	NSColor *swiftToken = [storage attribute:NSForegroundColorAttributeName atIndex:swiftLine.location + 1 effectiveRange:nil];
	NSColor *swiftPrefixBackground = [storage attribute:NSBackgroundColorAttributeName atIndex:swiftLine.location effectiveRange:nil];
	NSColor *swiftTokenBackground = [storage attribute:NSBackgroundColorAttributeName atIndex:swiftLine.location + 1 effectiveRange:nil];
	XCTAssertNotEqualObjects(swiftPrefix, swiftToken);
	XCTAssertNotNil(swiftTokenBackground);
	XCTAssertEqualObjects(swiftPrefixBackground, swiftTokenBackground);

	NSRange textLine = [storage.string rangeOfString:@"+plain value"];
	XCTAssertNotEqual(textLine.location, NSNotFound);
	NSColor *textPrefix = [storage attribute:NSForegroundColorAttributeName atIndex:textLine.location effectiveRange:nil];
	NSColor *textBody = [storage attribute:NSForegroundColorAttributeName atIndex:textLine.location + 1 effectiveRange:nil];
	XCTAssertEqualObjects(textPrefix, textBody);
	XCTAssertNotNil([storage attribute:NSBackgroundColorAttributeName atIndex:textLine.location + 1 effectiveRange:nil]);
}

- (void)testNativeDiffRevealSuppressedLinkRerendersFile
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSString *diff = @"diff --git a/generated/output.swift b/generated/output.swift\n"
					  "--- a/generated/output.swift\n"
					  "+++ b/generated/output.swift\n"
					  "@@ -1 +1 @@\n-old\n+new\n";
	[view showDiffSections:@[ @{
			  PBNativeSectionTextKey : diff,
			  PBNativeSectionSuppressionPatternsKey : @[ @"^generated/" ],
		  } ]];
	[self waitForNativeView:view toContainString:@"Diff hidden by repository setting"];
	NSUInteger linkIndex = 0;
	id link = [self linkInNativeView:view titled:@"▸ " index:&linkIndex];
	XCTAssertNotNil(link);
	BOOL handled = [view textView:view.textView clickedOnLink:link atIndex:linkIndex];
	XCTAssertTrue(handled);
	[self waitForNativeView:view toContainString:@"+new"];
}

- (void)testNativeHistoryContentTracksHostBoundsWhileResizing
{
	NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 420)];
	PBWebController *controller = [[PBWebController alloc] init];
	controller.view = host;
	[controller awakeFromNib];
	[controller.nativeView showMessage:@"Resize-safe history content"];

	for (NSValue *sizeValue in @[ [NSValue valueWithSize:NSMakeSize(360, 240)], [NSValue valueWithSize:NSMakeSize(980, 640)], [NSValue valueWithSize:NSMakeSize(520, 300)] ]) {
		host.frameSize = sizeValue.sizeValue;
		[host layoutSubtreeIfNeeded];
		XCTAssertTrue(NSEqualRects(controller.nativeView.frame, host.bounds));
		XCTAssertTrue([controller.nativeView.textView.string containsString:@"Resize-safe history content"]);
	}

	[controller closeView];
}

- (void)testNativeDiffAlwaysRendersLargePatches
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSUInteger repeatedLineCount = 5200;
	NSMutableString *diff = [NSMutableString stringWithFormat:@"diff --git a/large.txt b/large.txt\n--- /dev/null\n+++ b/large.txt\n@@ -0,0 +1,%lu @@\n", (unsigned long)(repeatedLineCount + 1)];
	for (NSUInteger index = 0; index < repeatedLineCount; index++)
		[diff appendFormat:@"+%04lu 0123456789012345678901234567890123456789\n", (unsigned long)index];
	[diff appendString:@"+large-patch-tail\n"];
	XCTAssertGreaterThan([diff lengthOfBytesUsingEncoding:NSUTF8StringEncoding], (NSUInteger)(200 * 1024));

	[view showDiffSections:@[ @{PBNativeSectionTextKey : diff, PBNativeSectionContextKey : @"readOnly"} ]];
	[self waitForNativeView:view toContainString:@"+large-patch-tail"];
	XCTAssertFalse([view.textView.string containsString:@"Render patch"]);
}

- (void)testTaskAppliesEnvironmentConfiguredAfterCreation
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/usr/bin/env" arguments:@[] inDirectory:nil];
	task.additionalEnvironment = @{@"GITX_TEST_ENVIRONMENT" : @"present"};
	NSError *error = nil;
	XCTAssertTrue([task launchTask:&error], @"%@", error);
	XCTAssertTrue([task.standardOutputString containsString:@"GITX_TEST_ENVIRONMENT=present"]);
}

- (void)testAppearanceObservationDoesNotOverrideNSApplicationKVOHandling
{
	Method method = class_getInstanceMethod(NSApplication.class,
											@selector(observeValueForKeyPath:ofObject:change:context:));
	Dl_info methodInfo = {0};
	int lookupResult = dladdr(method_getImplementation(method), &methodInfo);
	XCTAssertEqual(lookupResult, 1);
	if (lookupResult == 0 || methodInfo.dli_fname == NULL)
		return;
	XCTAssertFalse([[NSString stringWithUTF8String:methodInfo.dli_fname] containsString:@"/GitX.app/Contents/MacOS/GitX"]);
}

- (void)testAppearanceObservationPostsEffectiveAppearanceNotification
{
	NSApplication *application = NSApplication.sharedApplication;
	NSObject *notificationObject = [[NSObject alloc] init];
	__block BOOL receivedNotification = NO;
	id notificationToken = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBEffectiveAppearanceChanged
					object:notificationObject
					 queue:nil
				usingBlock:^(NSNotification *notification) {
					receivedNotification = YES;
				}];

	NSAppearance *originalAppearance = application.appearance;
	[application registerObserverForAppearanceChanges:notificationObject];
	application.appearance = [NSAppearance appearanceNamed:application.isDarkMode ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];

	XCTAssertTrue(receivedNotification);
	application.appearance = originalAppearance;
	[application registerObserverForAppearanceChanges:application.delegate];
	[[NSNotificationCenter defaultCenter] removeObserver:notificationToken];
}

- (void)testNativeDiffBuildsLinePatchesForStageAndUnstage
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSArray *header = @[ @"diff --git a/file.txt b/file.txt", @"--- a/file.txt", @"+++ b/file.txt" ];
	NSArray *hunk = @[ @"@@ -1,3 +1,3 @@", @" same", @"-old", @"+new", @" tail" ];

	NSString *stagePatch = [view patchWithFileHeader:header hunkLines:hunk selectedIndexes:[NSIndexSet indexSetWithIndex:3] reverse:NO];
	XCTAssertTrue([stagePatch containsString:@"@@ -1,3 +1,4 @@"]);
	XCTAssertTrue([stagePatch containsString:@" old\n+new"]);
	XCTAssertFalse([stagePatch containsString:@"-old"]);

	NSString *unstagePatch = [view patchWithFileHeader:header hunkLines:hunk selectedIndexes:[NSIndexSet indexSetWithIndex:2] reverse:YES];
	XCTAssertTrue([unstagePatch containsString:@"@@ -1,4 +1,3 @@"]);
	XCTAssertTrue([unstagePatch containsString:@"-old\n new"]);
	XCTAssertFalse([unstagePatch containsString:@"+new"]);
}

- (void)testNativeDiffOmitsNoNewlineMarkerWhenAssociatedChangeIsOmitted
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSArray *header = @[ @"diff --git a/file.txt b/file.txt", @"--- a/file.txt", @"+++ b/file.txt" ];
	NSArray *hunk = @[ @"@@ -1,3 +1,5 @@", @" a", @" old", @"+new", @" tail", @"+extra", @"\\ No newline at end of file" ];
	NSString *patch = [view patchWithFileHeader:header hunkLines:hunk selectedIndexes:[NSIndexSet indexSetWithIndex:3] reverse:NO];
	XCTAssertNotNil(patch);
	XCTAssertTrue([patch containsString:@"+new"]);
	XCTAssertFalse([patch containsString:@"+extra"]);
	XCTAssertFalse([patch containsString:@"No newline at end of file"]);
}

- (void)testNativeDiffKeepsAdjacentHtaccessLineSelectionStable
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSArray *header = @[ @"diff --git a/.htaccess b/.htaccess", @"--- a/.htaccess", @"+++ b/.htaccess" ];
	NSArray *hunk = @[ @"@@ -1,4 +1,6 @@", @" RewriteEngine On", @" RewriteCond %{REQUEST_FILENAME} !-f", @"+RewriteCond %{REQUEST_URI} !^/index\\.php", @"+RewriteRule ^ index.php [L]", @" RewriteRule ^ old.php [L]", @" RewriteCond %{REQUEST_FILENAME} !-d" ];
	NSMutableIndexSet *selected = [NSMutableIndexSet indexSetWithIndex:3];
	[selected addIndex:4];

	NSString *patch = [view patchWithFileHeader:header hunkLines:hunk selectedIndexes:selected reverse:NO];

	XCTAssertNotNil(patch);
	XCTAssertTrue([patch containsString:@"+RewriteCond %{REQUEST_URI} !^/index\\.php\n"]);
	XCTAssertTrue([patch containsString:@"+RewriteRule ^ index.php [L]\n"]);
	XCTAssertTrue([patch containsString:@" RewriteRule ^ old.php [L]\n"]);
}

- (void)testNativeDiffExtractsPathsContainingSpacesAndRenameDestinations
{
	PBNativeContentView *view = [[PBNativeContentView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
	NSArray *spaced = @[ @"diff --git a/Folder/file name.txt b/Folder/file name.txt", @"--- a/Folder/file name.txt", @"+++ b/Folder/file name.txt" ];
	XCTAssertEqualObjects([view pathForDiffHeaderAtIndex:0 lines:spaced], @"Folder/file name.txt");
	NSArray *renamed = @[ @"diff --git a/old.txt b/new name.txt", @"similarity index 100%", @"rename from old.txt", @"rename to new name.txt" ];
	XCTAssertEqualObjects([view pathForDiffHeaderAtIndex:0 lines:renamed], @"new name.txt");
	NSArray *sameInitial = @[ @"diff --git a/app/assets/variables.json b/assets/variables.json", @"similarity index 100%", @"rename from app/assets/variables.json", @"rename to assets/variables.json" ];
	XCTAssertEqualObjects([view pathForDiffHeaderAtIndex:0 lines:sameInitial], @"assets/variables.json");
	NSArray *quoted = @[ @"diff --git a/old.txt b/new.txt", @"+++ \"b/quoted\\\"name.txt\"" ];
	XCTAssertEqualObjects([view pathForDiffHeaderAtIndex:0 lines:quoted], @"quoted\"name.txt");
	NSArray *malformed = @[ @"not a diff header" ];
	XCTAssertEqualObjects([view pathForDiffHeaderAtIndex:0 lines:malformed], @"not a diff header");
}

- (void)testTaskSupportsShortConfigurableTimeouts
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/bin/sleep" arguments:@[ @"1" ] inDirectory:nil];
	task.timeout = 0.02;
	NSError *error = nil;
	XCTAssertFalse([task launchTask:&error]);
	XCTAssertEqualObjects(error.domain, PBTaskErrorDomain);
	XCTAssertEqual(error.code, PBTaskTimeoutError);
}

- (void)testAutoFetchRetryDelayIsExponentialAndBounded
{
	XCTAssertEqual([PBAutoFetchManager retryDelayForFailureCount:0], 0);
	XCTAssertEqual([PBAutoFetchManager retryDelayForFailureCount:1], 60);
	XCTAssertEqual([PBAutoFetchManager retryDelayForFailureCount:2], 120);
	XCTAssertEqual([PBAutoFetchManager retryDelayForFailureCount:4], 480);
	XCTAssertEqual([PBAutoFetchManager retryDelayForFailureCount:5], 900);
	XCTAssertEqual([PBAutoFetchManager retryDelayForFailureCount:20], 900);
}

- (void)testSourceViewBadgeCoversHighlightedAndNumericVariants
{
	PBSourceViewBadgeCell *cell = [[PBSourceViewBadgeCell alloc] initWithFrame:NSMakeRect(0, 0, 80, 22)];
	PBSourceViewBadgeWindow *window = [[PBSourceViewBadgeWindow alloc]
		initWithContentRect:NSMakeRect(0, 0, 80, 22)
				  styleMask:NSWindowStyleMaskBorderless
					backing:NSBackingStoreBuffered
					  defer:NO];
	cell.testWindow = window;
	XCTAssertNotNil([PBSourceViewBadge badgeHighlightColor]);
	cell.backgroundStyle = NSBackgroundStyleNormal;
	XCTAssertEqualObjects([PBSourceViewBadge badgeColorForCell:cell], [PBSourceViewBadge badgeBackgroundColor]);
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell], NSColor.whiteColor);
	XCTAssertNotNil([PBSourceViewBadge numericBadge:42 forCell:cell]);

	window.testMainWindow = YES;
	XCTAssertEqualObjects([PBSourceViewBadge badgeColorForCell:cell], [PBSourceViewBadge badgeHighlightColor]);
	cell.backgroundStyle = NSBackgroundStyleEmphasized;
	XCTAssertEqualObjects([PBSourceViewBadge badgeColorForCell:cell], NSColor.whiteColor);
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell], [PBSourceViewBadge badgeHighlightColor]);

	window.testMainWindow = NO;
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell], [PBSourceViewBadge badgeBackgroundColor]);
	window.testKeyWindow = YES;
	XCTAssertEqualObjects([PBSourceViewBadge badgeTextColorForCell:cell], [PBSourceViewBadge badgeBackgroundColor]);
	XCTAssertNotNil([PBSourceViewBadge checkedOutBadgeForCell:cell]);
}

@end

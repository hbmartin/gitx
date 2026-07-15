#import <XCTest/XCTest.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "PBGitDefaults.h"
#import "PBAutoFetchManager.h"
#import "PBMacros.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitWindowController.h"
#import "PBHistoryArrayController.h"
#import "PBHighlighting.h"
#import "PBFileChangesTableView.h"
#import "PBNativeContentView.h"
#import "PBTask.h"
#import "PBWebController.h"
#import "NSAppearance+PBDarkMode.h"

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
@end

@interface PBAutoFetchManager (GitXFeatureTests)
+ (NSTimeInterval)retryDelayForFailureCount:(NSUInteger)failureCount;
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

- (void)testAutoFetchDefaultsClampInterval
{
	[PBGitDefaults setAutoFetchIntervalMinutes:0];
	XCTAssertEqual([PBGitDefaults autoFetchIntervalMinutes], 1);
	[PBGitDefaults setAutoFetchIntervalMinutes:2000];
	XCTAssertEqual([PBGitDefaults autoFetchIntervalMinutes], 1440);
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeOpenRepositories];
	XCTAssertEqual([PBGitDefaults autoFetchScope], PBAutoFetchScopeOpenRepositories);
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

@end

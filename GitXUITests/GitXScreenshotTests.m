//
//  GitXScreenshotTests.m
//  GitXUITests
//
//  Screenshot tests using XCUIApplication.
//  Screenshots are saved as test attachments and uploaded as CI artifacts.
//  No external dependencies required.
//

#import <XCTest/XCTest.h>

@interface GitXScreenshotTests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@property (nonatomic, strong) NSMutableArray<NSString *> *temporaryRepositoryPaths;
- (NSString *)makeDirtyRepositoryFixture;
@end

@implementation GitXScreenshotTests

- (void)setUp
{
	[super setUp];
	self.continueAfterFailure = NO;
	self.app = [[XCUIApplication alloc] init];
	self.app.launchArguments = @[ @"-ApplePersistenceIgnoreState", @"YES" ];
	self.temporaryRepositoryPaths = [NSMutableArray array];

	// An explicit environment override is useful for local one-off runs. CI
	// checks out its fixed screenshot repository at the path below.
	NSDictionary *env = [[NSProcessInfo processInfo] environment];
	NSString *repoPath = env[@"GITX_SCREENSHOT_REPO"];
	NSString *ciRepositoryPath = @"/tmp/gitx-screenshot-repo";
	if (!repoPath.length && [[NSFileManager defaultManager] fileExistsAtPath:ciRepositoryPath]) {
		repoPath = ciRepositoryPath;
	}

	if (!repoPath.length) {
		// Fallback: a fixture repo bundled with the test target
		NSBundle *bundle = [NSBundle bundleForClass:[self class]];
		NSURL *bundledRepo = [bundle URLForResource:@"testrepo" withExtension:nil];
		if (bundledRepo && [[NSFileManager defaultManager] fileExistsAtPath:bundledRepo.path]) {
			repoPath = bundledRepo.path;
		}
	}
	if (!repoPath.length) {
		repoPath = [self makeDirtyRepositoryFixture];
	}

	NSLog(@"[GitXScreenshotTests] repoPath = %@", repoPath ?: @"(none)");

	if (repoPath) {
		// Passed to the app via applicationDidFinishLaunching: which opens
		// the repo directly, giving the test a reliable document window.
		self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : repoPath};
	}

	[self.app launch];
}

- (void)tearDown
{
	[self.app terminate];
	for (NSString *path in self.temporaryRepositoryPaths) {
		[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
	}
	[super tearDown];
}

// MARK: - Helpers

- (BOOL)waitForWindow
{
	XCUIElement *window = self.app.windows.firstMatch;
	if ([window waitForExistenceWithTimeout:20]) {
		return YES;
	}
	// Activate the app and give it one more chance — it may have launched
	// but not yet brought its window to the front.
	[self.app activate];
	return [self.app.windows.firstMatch waitForExistenceWithTimeout:10];
}

- (void)saveScreenshotNamed:(NSString *)name
{
	XCUIScreenshot *screenshot = [[XCUIScreen mainScreen] screenshot];
	XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:screenshot];
	attachment.name = name;
	attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
	[self addAttachment:attachment];
}

- (void)saveWindowScreenshotNamed:(NSString *)name
{
	XCUIElement *window = self.app.windows.firstMatch;
	if (!window.exists) {
		[self saveScreenshotNamed:name]; // fall back to full screen
		return;
	}
	XCUIScreenshot *screenshot = [window screenshot];
	XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:screenshot];
	attachment.name = name;
	attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
	[self addAttachment:attachment];
}

- (BOOL)runGit:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory
{
	NSTask *task = [[NSTask alloc] init];
	// /usr/bin/git delegates through xcrun, which refuses to run from the UI
	// test runner's sandbox. Invoke the selected Xcode's Git binary directly.
	NSString *developerDirectory = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
	if (!developerDirectory.length) {
		developerDirectory = @"/Applications/Xcode.app/Contents/Developer";
	}
	NSString *gitPath = [developerDirectory stringByAppendingPathComponent:@"usr/bin/git"];
	if (![[NSFileManager defaultManager] isExecutableFileAtPath:gitPath]) {
		gitPath = @"/usr/bin/git";
	}
	task.executableURL = [NSURL fileURLWithPath:gitPath];
	task.arguments = arguments;
	task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
	NSError *error = nil;
	[task launchAndReturnError:&error];
	[task waitUntilExit];
	return error == nil && task.terminationStatus == 0;
}

- (NSString *)makeDirtyRepositoryFixture
{
	NSString *repositoryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"gitx-dirty-%@", NSUUID.UUID.UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:repositoryPath withIntermediateDirectories:YES attributes:nil error:nil];
	[self.temporaryRepositoryPaths addObject:repositoryPath];
	XCTAssertTrue(([self runGit:@[ @"init", @"-q", @"-b", @"main" ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"config", @"user.name", @"GitX Tests" ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"config", @"user.email", @"tests@gitx.invalid" ] inDirectory:repositoryPath]));
	[@"tracked\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"tracked.swift"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	XCTAssertTrue(([self runGit:@[ @"add", @"tracked.swift" ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"commit", @"-q", @"-m", @"Initial" ] inDirectory:repositoryPath]));
	[@"tracked\nsecond\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"tracked.swift"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	XCTAssertTrue(([self runGit:@[ @"add", @"tracked.swift" ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"commit", @"-q", @"-m", @"Second" ] inDirectory:repositoryPath]));
	[@"tracked\nsecond\nthird\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"tracked.swift"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	XCTAssertTrue(([self runGit:@[ @"add", @"tracked.swift" ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"commit", @"-q", @"-m", @"Third" ] inDirectory:repositoryPath]));
	[@"tracked\nsecond\nthird\nchanged\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"tracked.swift"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	[@"new\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"new.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	return repositoryPath;
}

- (XCUIElement *)selectHistoryForCurrentBranch
{
	[self.app activate];
	NSPredicate *branchName = [NSPredicate predicateWithFormat:@"value == 'main' OR value == 'master'"];
	XCUIElement *branch = [self.app.staticTexts matchingPredicate:branchName].firstMatch;
	XCTAssertTrue([branch waitForExistenceWithTimeout:10], @"The repository's current branch should be visible in the sidebar");
	[branch click];
	XCUIElement *table = self.app.tables[@"CommitList"];
	XCTAssertTrue([table waitForExistenceWithTimeout:15], @"Selecting the current branch should open history");
	return table;
}

// MARK: - Tests

- (void)testMainWindowExists
{
	XCTAssertTrue([self waitForWindow],
				  @"Main window should appear within 30 seconds");
	[self saveWindowScreenshotNamed:@"main-window"];
}

- (void)testHistoryTabScreenshot
{
	XCTAssertTrue([self waitForWindow], @"History requires a repository window");
	[self selectHistoryForCurrentBranch];
	[self saveWindowScreenshotNamed:@"history-view"];
}

- (void)testStagingTabScreenshot
{
	XCTAssertTrue([self waitForWindow], @"Staging requires a repository window");
	XCUIElement *sidebar = self.app.outlines[@"RepositorySidebar"];
	XCTAssertTrue([sidebar waitForExistenceWithTimeout:10], @"The repository sidebar should be accessible");
	XCUIElement *stageItem = sidebar.staticTexts[@"Stage"];
	XCTAssertTrue([stageItem waitForExistenceWithTimeout:10], @"The Stage item should be visible in the sidebar");
	[stageItem click];

	[self saveWindowScreenshotNamed:@"staging-view"];
}

- (void)testUncommittedChangesRowAppearsForDirtyRepository
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow]);
	[self selectHistoryForCurrentBranch];

	XCUIElement *workingState = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value BEGINSWITH 'Uncommitted Changes'"]].firstMatch;
	XCTAssertTrue([workingState waitForExistenceWithTimeout:15], @"Dirty repositories should pin an Uncommitted Changes row above history");
	[self saveWindowScreenshotNamed:@"uncommitted-changes-row"];
}

- (void)testMultipleCommitSelectionShowsDiffPresentationControl
{
	XCTAssertTrue([self waitForWindow], @"Commit selection requires a repository window");
	XCUIElement *table = [self selectHistoryForCurrentBranch];
	XCUIElement *firstCommit = [table.tableRows elementBoundByIndex:1];
	XCUIElement *secondCommit = [table.tableRows elementBoundByIndex:2];
	XCTAssertTrue([firstCommit waitForExistenceWithTimeout:15]);
	XCTAssertTrue([secondCommit waitForExistenceWithTimeout:15], @"The screenshot repository must contain at least two commits plus working state");
	[firstCommit click];
	[XCUIElement performWithKeyModifiers:XCUIKeyModifierCommand
								   block:^{
									   [secondCommit click];
								   }];

	XCUIElement *presentation = [[self.app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == 'MultiCommitDiffPresentation'"]];
	XCTAssertTrue([presentation waitForExistenceWithTimeout:10]);
	[self saveWindowScreenshotNamed:@"multiple-commit-diff"];
}

- (void)testHistoryAndFetchPreferencesAreAvailable
{
	XCTAssertTrue([self waitForWindow], @"Preferences require the application to finish launching");
	[self.app activate];
	[self.app.menuBars.menuBarItems[@"GitX"] click];
	[self.app.menuItems[@"Settings…"] click];
	XCUIElement *preferences = self.app.dialogs.firstMatch;
	XCTAssertTrue([preferences waitForExistenceWithTimeout:5]);
	XCUIElement *pane = preferences.toolbars.buttons[@"History & Fetch"];
	if (pane.exists) {
		[pane click];
	} else {
		XCUIElement *more = preferences.popUpButtons[@"more toolbar items"];
		XCTAssertTrue([more waitForExistenceWithTimeout:5]);
		[more click];
		XCUIElement *menuItem = self.app.menuItems[@"History & Fetch"];
		XCTAssertTrue([menuItem waitForExistenceWithTimeout:5]);
		[menuItem click];
	}
	XCTAssertTrue([preferences.checkBoxes[@"Allow commit columns to sort history"] waitForExistenceWithTimeout:5]);
	XCTAssertTrue(preferences.popUpButtons.firstMatch.exists);
	[self saveWindowScreenshotNamed:@"history-fetch-preferences"];
}

- (void)testAppearancePreferenceOffersAutomaticLightAndDark
{
	XCTAssertTrue([self waitForWindow], @"Preferences require the application to finish launching");
	[self.app activate];
	[self.app.menuBars.menuBarItems[@"GitX"] click];
	[self.app.menuItems[@"Settings…"] click];
	XCUIElement *preferences = self.app.dialogs.firstMatch;
	XCTAssertTrue([preferences waitForExistenceWithTimeout:5]);

	XCUIElement *generalPane = preferences.toolbars.buttons[@"General"];
	XCTAssertTrue([generalPane waitForExistenceWithTimeout:5]);
	[generalPane click];

	XCUIElement *appearance = preferences.popUpButtons[@"AppearancePreference"];
	XCTAssertTrue([appearance waitForExistenceWithTimeout:5]);
	NSString *originalValue = appearance.value;

	@try {
		for (NSString *title in @[ @"Dark", @"Light", @"Automatic (System)" ]) {
			[appearance click];
			XCUIElement *choice = self.app.menuItems[title];
			XCTAssertTrue([choice waitForExistenceWithTimeout:5]);
			[choice click];
			XCTAssertEqualObjects(appearance.value, title);
			[NSThread sleepForTimeInterval:0.2];
			[self saveWindowScreenshotNamed:[NSString stringWithFormat:@"appearance-%@", title.lowercaseString]];
		}
	} @finally {
		if (originalValue.length && ![appearance.value isEqual:originalValue]) {
			[appearance click];
			[self.app.menuItems[originalValue] click];
		}
	}
}

// - (void)testFullScreenScreenshot {
//     // Capture the entire screen — useful for catching system-level visual regressions
//     [NSThread sleepForTimeInterval:1.0]; // let the app settle
//     [self saveScreenshotNamed:@"full-screen"];
// }

- (void)testCommitContextMenuScreenshot
{
	XCTAssertTrue([self waitForWindow], @"The context menu requires a repository window");
	XCUIElement *table = [self selectHistoryForCurrentBranch];
	XCUIElement *window = self.app.windows.firstMatch;
	XCUIElement *firstRow = [table.tableRows elementBoundByIndex:0];
	XCTAssertTrue([firstRow waitForExistenceWithTimeout:15], @"The commit list should contain a row");

	// Right-click to open the context menu
	[firstRow rightClick];

	// Wait for the menu to appear
	XCUIElement *menu = self.app.menus.firstMatch;
	XCTAssertTrue([menu waitForExistenceWithTimeout:5], @"Right-clicking a commit should open its context menu");

	[NSThread sleepForTimeInterval:0.3]; // let the menu fully render
	[self saveWindowScreenshotNamed:@"commit-context-menu"];

	// Dismiss the menu
	[window typeKey:XCUIKeyboardKeyEscape modifierFlags:0];
}

@end

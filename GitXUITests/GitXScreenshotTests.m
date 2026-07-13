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
@end

@implementation GitXScreenshotTests

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.app = [[XCUIApplication alloc] init];

    // GITX_UITEST_REPO is set by the scheme to $(GITX_SCREENSHOT_REPO).
    // Locally this expands to $(SRCROOT). On CI, xcodebuild overrides
    // GITX_SCREENSHOT_REPO=/tmp/gitx-screenshot-repo (the fixed commit checkout).
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSString *repoPath = env[@"GITX_UITEST_REPO"];

    if (!repoPath) {
        // Fallback: a fixture repo bundled with the test target
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSURL *bundledRepo = [bundle URLForResource:@"testrepo" withExtension:nil];
        if (bundledRepo && [[NSFileManager defaultManager] fileExistsAtPath:bundledRepo.path]) {
            repoPath = bundledRepo.path;
        }
    }

    NSLog(@"[GitXScreenshotTests] repoPath = %@", repoPath ?: @"(none)");

    if (repoPath) {
        // Passed to the app via applicationDidFinishLaunching: which opens
        // the repo directly, giving the test a reliable document window.
        self.app.launchEnvironment = @{@"GITX_UITEST_REPO": repoPath};
    }

    [self.app launch];
}

- (void)tearDown {
    [self.app terminate];
    [super tearDown];
}

// MARK: - Helpers

- (BOOL)waitForWindow {
    XCUIElement *window = self.app.windows.firstMatch;
    if ([window waitForExistenceWithTimeout:20]) {
        return YES;
    }
    // Activate the app and give it one more chance — it may have launched
    // but not yet brought its window to the front.
    [self.app activate];
    return [self.app.windows.firstMatch waitForExistenceWithTimeout:10];
}

- (void)saveScreenshotNamed:(NSString *)name {
    XCUIScreenshot *screenshot = [[XCUIScreen mainScreen] screenshot];
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:screenshot];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

- (void)saveWindowScreenshotNamed:(NSString *)name {
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

- (BOOL)runGit:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory {
    NSTask *task = [[NSTask alloc] init];
    // /usr/bin/git delegates through xcrun, which refuses to run from the UI
    // test runner's sandbox. Invoke Xcode's real Git binary directly.
    task.executableURL = [NSURL fileURLWithPath:@"/Applications/Xcode.app/Contents/Developer/usr/bin/git"];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    NSError *error = nil;
    [task launchAndReturnError:&error];
    [task waitUntilExit];
    return error == nil && task.terminationStatus == 0;
}

- (NSString *)makeDirtyRepositoryFixture {
    NSString *repositoryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"gitx-dirty-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:repositoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    XCTAssertTrue(([self runGit:@[@"init", @"-q"] inDirectory:repositoryPath]));
    XCTAssertTrue(([self runGit:@[@"config", @"user.name", @"GitX Tests"] inDirectory:repositoryPath]));
    XCTAssertTrue(([self runGit:@[@"config", @"user.email", @"tests@gitx.invalid"] inDirectory:repositoryPath]));
    [@"tracked\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"tracked.swift"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue(([self runGit:@[@"add", @"tracked.swift"] inDirectory:repositoryPath]));
    XCTAssertTrue(([self runGit:@[@"commit", @"-q", @"-m", @"Initial"] inDirectory:repositoryPath]));
    [@"tracked\nchanged\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"tracked.swift"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"new\n" writeToFile:[repositoryPath stringByAppendingPathComponent:@"new.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return repositoryPath;
}

- (XCUIElement *)selectHistoryForCurrentBranch {
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

- (void)testMainWindowExists {
    XCTAssertTrue([self waitForWindow],
                  @"Main window should appear within 30 seconds");
    [self saveWindowScreenshotNamed:@"main-window"];
}

- (void)testHistoryTabScreenshot {
    if (![self waitForWindow]) { return; }
    [self saveWindowScreenshotNamed:@"history-view"];
}

- (void)testStagingTabScreenshot {
    if (![self waitForWindow]) { return; }

    // Click the Stage tab / toolbar button if present
    XCUIElement *stageButton = self.app.toolbars.buttons[@"Stage"];
    if (!stageButton.exists) {
        // Try as a tab or segmented control
        stageButton = [self.app.windows.firstMatch.buttons elementMatchingType:XCUIElementTypeButton
                                                                    identifier:@"Stage"];
    }
    if (stageButton.exists) {
        [stageButton click];
        [NSThread sleepForTimeInterval:0.5];
    }

    [self saveWindowScreenshotNamed:@"staging-view"];
}

- (void)testUncommittedChangesRowAppearsForDirtyRepository {
    [self.app terminate];
    NSString *fixture = [self makeDirtyRepositoryFixture];
    self.app.launchEnvironment = @{ @"GITX_UITEST_REPO" : fixture };
    [self.app launch];
    XCTAssertTrue([self waitForWindow]);
	[self selectHistoryForCurrentBranch];

    XCUIElement *workingState = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value BEGINSWITH 'Uncommitted Changes'"]].firstMatch;
    XCTAssertTrue([workingState waitForExistenceWithTimeout:15], @"Dirty repositories should pin an Uncommitted Changes row above history");
    [self saveWindowScreenshotNamed:@"uncommitted-changes-row"];
}

- (void)testMultipleCommitSelectionShowsDiffPresentationControl {
    if (![self waitForWindow]) { return; }
	XCUIElement *table = [self selectHistoryForCurrentBranch];
    [NSThread sleepForTimeInterval:1.0];
    XCTAssertGreaterThan(table.tableRows.count, 2);
    [[table.tableRows elementBoundByIndex:1] click];
    [XCUIElement performWithKeyModifiers:XCUIKeyModifierCommand block:^{
        [[table.tableRows elementBoundByIndex:2] click];
    }];

    XCUIElement *presentation = [[self.app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == 'MultiCommitDiffPresentation'"]];
    XCTAssertTrue([presentation waitForExistenceWithTimeout:10]);
    [self saveWindowScreenshotNamed:@"multiple-commit-diff"];
}

- (void)testHistoryAndFetchPreferencesAreAvailable {
    if (![self waitForWindow]) { return; }
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

// - (void)testFullScreenScreenshot {
//     // Capture the entire screen — useful for catching system-level visual regressions
//     [NSThread sleepForTimeInterval:1.0]; // let the app settle
//     [self saveScreenshotNamed:@"full-screen"];
// }

- (void)testCommitContextMenuScreenshot {
    if (![self waitForWindow]) { return; }

    // The commit list is a table — find the first (most recent) commit row
    XCUIElement *window = self.app.windows.firstMatch;
    XCUIElement *table = window.tables.firstMatch;
    if (![table waitForExistenceWithTimeout:10]) {
        NSLog(@"[GitXScreenshotTests] Commit table not found, skipping context menu screenshot");
        return;
    }

    // Let the history list fully load
    [NSThread sleepForTimeInterval:1.0];

    XCUIElement *firstRow = [table.tableRows elementBoundByIndex:0];
    if (!firstRow.exists) {
        NSLog(@"[GitXScreenshotTests] No commit rows found, skipping context menu screenshot");
        return;
    }

    // Right-click to open the context menu
    [firstRow rightClick];

    // Wait for the menu to appear
    XCUIElement *menu = self.app.menus.firstMatch;
    if (![menu waitForExistenceWithTimeout:5]) {
        NSLog(@"[GitXScreenshotTests] Context menu did not appear");
        return;
    }

    [NSThread sleepForTimeInterval:0.3]; // let the menu fully render
    [self saveWindowScreenshotNamed:@"commit-context-menu"];

    // Dismiss the menu
    [window typeKey:XCUIKeyboardKeyEscape modifierFlags:0];
}

@end

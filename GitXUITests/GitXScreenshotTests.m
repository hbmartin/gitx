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
- (nullable NSString *)gitOutput:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory;
- (nullable NSString *)configureOriginForRepository:(NSString *)repositoryPath;
- (void)openPreferencesWaitingForElement:(XCUIElement *)element;
- (void)launchWithStagingLayout:(NSInteger)layout;
- (void)openStagingViewWaitingForTable:(NSString *)tableIdentifier;
@end

@implementation GitXScreenshotTests

- (void)setUp
{
	[super setUp];
	self.continueAfterFailure = NO;
	self.app = [[XCUIApplication alloc] init];
	self.app.launchArguments = @[
		@"-ApplePersistenceIgnoreState", @"YES",
		@"-AppleLanguages", @"(en)",
		@"-AppleLocale", @"en_US_POSIX",
		@"-NSAutomaticWindowAnimationsEnabled", @"NO",
		@"-PBGitXPreferenceViewIdentifier", @"General"
	];
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

- (void)waitForElement:(XCUIElement *)element toHaveValue:(id)value timeout:(NSTimeInterval)timeout
{
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"value == %@", value];
	XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:element];
	[self waitForExpectations:@[ expectation ] timeout:timeout];
}

- (void)openPreferencesWaitingForElement:(XCUIElement *)element
{
	XCTAssertTrue([self waitForWindow], @"Preferences require the application to finish launching");
	[self.app activate];
	if ([element waitForExistenceWithTimeout:1]) return;
	XCUIElement *applicationMenu = self.app.menuBars.menuBarItems[@"GitX"];
	XCTAssertTrue([applicationMenu waitForExistenceWithTimeout:5], @"Preferences require the GitX application menu");
	[applicationMenu click];
	XCUIElement *settingsItem = self.app.menuItems[@"Settings…"];
	XCTAssertTrue([settingsItem waitForExistenceWithTimeout:5], @"The GitX application menu should offer Settings");
	[settingsItem click];
	XCTAssertTrue([element waitForExistenceWithTimeout:10],
				  @"The requested preferences pane should expose %@", element);
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

- (NSString *)gitOutput:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory
{
	NSTask *task = [[NSTask alloc] init];
	NSString *developerDirectory = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
	if (!developerDirectory.length) {
		developerDirectory = @"/Applications/Xcode.app/Contents/Developer";
	}
	NSString *gitPath = [developerDirectory stringByAppendingPathComponent:@"usr/bin/git"];
	if (![[NSFileManager defaultManager] isExecutableFileAtPath:gitPath]) {
		gitPath = @"/usr/bin/git";
	}

	NSPipe *outputPipe = [NSPipe pipe];
	task.executableURL = [NSURL fileURLWithPath:gitPath];
	task.arguments = arguments;
	task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
	task.standardOutput = outputPipe;
	task.standardError = [NSFileHandle fileHandleWithNullDevice];
	NSError *error = nil;
	if (![task launchAndReturnError:&error]) return nil;
	NSData *output = [outputPipe.fileHandleForReading readDataToEndOfFile];
	[task waitUntilExit];
	if (task.terminationStatus != 0) return nil;

	NSString *string = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
	return [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)configureOriginForRepository:(NSString *)repositoryPath
{
	NSString *remotePath = [repositoryPath stringByAppendingString:@"-remote.git"];
	[self.temporaryRepositoryPaths addObject:remotePath];
	XCTAssertTrue(([self runGit:@[ @"init", @"--bare", @"--quiet", remotePath ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"remote", @"add", @"origin", remotePath ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"push", @"--quiet", @"--set-upstream", @"origin", @"main" ] inDirectory:repositoryPath]));
	return remotePath;
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
	XCTAssertTrue([branch waitForExistenceWithTimeout:30], @"The repository's current branch should be visible in the sidebar");
	[branch click];
	XCUIElement *table = self.app.tables[@"CommitList"];
	XCTAssertTrue([table waitForExistenceWithTimeout:30], @"Selecting the current branch should open history");
	XCTAssertTrue([table.tableRows.firstMatch waitForExistenceWithTimeout:30],
				  @"Repository history should publish its first observable row before UI actions continue");
	return table;
}

- (void)launchWithStagingLayout:(NSInteger)layout
{
	[self.app terminate];
	NSMutableArray<NSString *> *arguments = [self.app.launchArguments mutableCopy];
	NSString *layoutFlag = @"-PBStagingFileListLayout";
	for (NSInteger index = (NSInteger)arguments.count - 1; index >= 0; index--) {
		if (![arguments[index] isEqualToString:layoutFlag])
			continue;
		[arguments removeObjectAtIndex:(NSUInteger)index];
		if ((NSUInteger)index < arguments.count)
			[arguments removeObjectAtIndex:(NSUInteger)index];
	}
	[arguments addObjectsFromArray:@[ @"-PBStagingFileListLayout", [NSString stringWithFormat:@"%ld", layout] ]];
	self.app.launchArguments = arguments;
	[self.app launch];
}

- (void)openStagingViewWaitingForTable:(NSString *)tableIdentifier
{
	XCTAssertTrue([self waitForWindow], @"Staging requires a repository window");
	XCUIElement *table = self.app.tables[@"CommitList"];
	XCTAssertTrue([table waitForExistenceWithTimeout:15], @"History should be open before showing uncommitted changes");
	XCUIElement *stagingTable = self.app.tables[tableIdentifier];
	XCUIElement *workingStateRow = self.app.staticTexts[@"Uncommitted Changes"];
	XCUIElement *workingStateToolbarButton = self.app.buttons[@"Uncommitted Changes"];
	NSPredicate *stagingReady = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return stagingTable.exists || workingStateRow.exists || workingStateToolbarButton.exists;
	}];
	XCTNSPredicateExpectation *readyExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:stagingReady object:self.app];
	[self waitForExpectations:@[ readyExpectation ] timeout:30];
	// Exercise the remapped entry point: Cmd-2 selects the Uncommitted
	// Changes row, which swaps the Details tab to the staging pane.
	if (!stagingTable.exists) {
		[self.app activate];
		[self.app.windows.firstMatch typeKey:@"2" modifierFlags:XCUIKeyModifierCommand];
	}
	if (![stagingTable waitForExistenceWithTimeout:3]) {
		[self.app activate];
		XCTAssertTrue([workingStateToolbarButton waitForExistenceWithTimeout:5],
					  @"Staging should expose the Uncommitted Changes toolbar button as a fallback");
		[workingStateToolbarButton click];
	}
	XCTAssertTrue([stagingTable waitForExistenceWithTimeout:10],
				  @"The %@ list should be ready before using the staging pane", tableIdentifier);
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
	[self launchWithStagingLayout:0];
	[self selectHistoryForCurrentBranch];
	[self openStagingViewWaitingForTable:@"PendingFiles"];
	XCTAssertTrue(self.app.tables[@"PendingFiles"].exists);
	XCUIElement *diff = self.app.textViews[@"NativeContentText"];
	XCTAssertTrue([diff waitForExistenceWithTimeout:10]);
	// The pane selects the first pending file automatically, so the diff
	// pane opens on a staging-chrome hunk rather than a placeholder.
	NSPredicate *initialDiff = [NSPredicate predicateWithFormat:@"value CONTAINS 'Hunk 1'"];
	[self waitForExpectations:@[ [[XCTNSPredicateExpectation alloc] initWithPredicate:initialDiff object:diff] ] timeout:10];

	[self saveWindowScreenshotNamed:@"staging-view"];
}

- (void)testSplitStagingTabScreenshot
{
	[self launchWithStagingLayout:1];
	[self selectHistoryForCurrentBranch];
	[self openStagingViewWaitingForTable:@"UnstagedFiles"];
	XCTAssertTrue([self.app.tables[@"StagedFiles"] waitForExistenceWithTimeout:10]);
	XCUIElement *diff = self.app.textViews[@"NativeContentText"];
	XCTAssertTrue([diff waitForExistenceWithTimeout:10]);
	NSPredicate *initialDiff = [NSPredicate predicateWithFormat:@"value CONTAINS 'Hunk 1'"];
	[self waitForExpectations:@[ [[XCTNSPredicateExpectation alloc] initWithPredicate:initialDiff object:diff] ] timeout:10];

	[self saveWindowScreenshotNamed:@"staging-view-split"];
}

- (void)testStagingOptionsDoNotOfferWhitespaceFiltering
{
	[self launchWithStagingLayout:0];
	[self selectHistoryForCurrentBranch];
	[self openStagingViewWaitingForTable:@"PendingFiles"];
	XCUIElement *options = self.app.buttons[@"StagingViewOptions"];
	XCTAssertTrue([options waitForExistenceWithTimeout:10]);
	[options click];
	XCUIElement *menu = options.menus.firstMatch;
	XCTAssertTrue([menu waitForExistenceWithTimeout:5]);
	XCTAssertTrue([menu.menuItems[@"openExternalDiff:"] waitForExistenceWithTimeout:5]);
	XCTAssertFalse(menu.menuItems[@"changeWhitespaceVisibility:"].exists);
	[self saveScreenshotNamed:@"staging-options"];
}

- (void)testStagingViewRemainsActiveAfterMovingWindow
{
	[self launchWithStagingLayout:0];
	[self selectHistoryForCurrentBranch];
	[self openStagingViewWaitingForTable:@"PendingFiles"];
	XCUIElement *diff = self.app.textViews[@"NativeContentText"];
	XCTAssertTrue([diff waitForExistenceWithTimeout:10]);
	NSPredicate *initialDiff = [NSPredicate predicateWithFormat:@"value CONTAINS 'Hunk 1'"];
	[self waitForExpectations:@[ [[XCTNSPredicateExpectation alloc] initWithPredicate:initialDiff object:diff] ] timeout:10];

	XCUIElement *window = self.app.windows.firstMatch;
	CGRect originalFrame = window.frame;
	XCUICoordinate *titleBar = [[window coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
		coordinateWithOffset:CGVectorMake(originalFrame.size.width * 0.5, 12)];
	XCUICoordinate *destination = [titleBar coordinateWithOffset:CGVectorMake(80, 50)];
	[titleBar pressForDuration:0.1 thenDragToCoordinate:destination];
	NSPredicate *frameChanged = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return !CGPointEqualToPoint(window.frame.origin, originalFrame.origin);
	}];
	XCTNSPredicateExpectation *moveExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:frameChanged object:window];
	[self waitForExpectations:@[ moveExpectation ] timeout:5];

	XCTAssertTrue([[diff.value description] containsString:@"Hunk 1"]);
	XCTAssertTrue(self.app.tables[@"PendingFiles"].hittable);
	[self saveWindowScreenshotNamed:@"staging-view-after-window-move"];
}

- (void)testPartiallyStagedAdditionShowsOnlyTheIndexedContent
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	XCTAssertTrue(([self runGit:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] inDirectory:fixture]));
	XCTAssertTrue(([self runGit:@[ @"clean", @"-fd", @"--quiet" ] inDirectory:fixture]));
	NSString *newPath = [fixture stringByAppendingPathComponent:@"partial.txt"];
	XCTAssertTrue([@"staged line\n" writeToFile:newPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	XCTAssertTrue(([self runGit:@[ @"add", @"partial.txt" ] inDirectory:fixture]));
	XCTAssertTrue([@"staged line\nunstaged line\n" writeToFile:newPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self launchWithStagingLayout:1];
	[self openStagingViewWaitingForTable:@"UnstagedFiles"];

	XCUIElement *stagedTable = self.app.tables[@"StagedFiles"];
	XCUIElement *unstagedTable = self.app.tables[@"UnstagedFiles"];
	XCUIElement *stagedFile = stagedTable.staticTexts[@"partial.txt"];
	if (![stagedFile waitForExistenceWithTimeout:10]) {
		[self.app.windows.firstMatch typeKey:@"r" modifierFlags:XCUIKeyModifierCommand];
	}
	XCTAssertTrue([stagedFile waitForExistenceWithTimeout:15]);
	XCTAssertTrue([unstagedTable.staticTexts[@"partial.txt"] waitForExistenceWithTimeout:10]);
	XCUIElement *diff = self.app.textViews.firstMatch;
	NSPredicate *indexedContent = [NSPredicate predicateWithFormat:@"value CONTAINS 'staged line' AND NOT value CONTAINS 'unstaged line'"];
	XCTNSPredicateExpectation *initialSelection = [[XCTNSPredicateExpectation alloc] initWithPredicate:indexedContent object:diff];
	if ([XCTWaiter waitForExpectations:@[ initialSelection ] timeout:2] != XCTWaiterResultCompleted) {
		[stagedFile click];
	}
	XCTNSPredicateExpectation *diffExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:indexedContent object:diff];
	[self waitForExpectations:@[ diffExpectation ] timeout:15];
	[self saveWindowScreenshotNamed:@"partially-staged-addition-index-diff"];
}

- (void)testHistoryRemainsUsableAfterResizingWhileHidden
{
	[self launchWithStagingLayout:0];
	XCTAssertTrue([self waitForWindow]);
	[self openStagingViewWaitingForTable:@"PendingFiles"];
	XCUIElement *window = self.app.windows.firstMatch;
	CGRect originalFrame = window.frame;
	XCUIElement *resizeButton = window.buttons[XCUIIdentifierFullScreenWindow];
	if (!resizeButton.exists) resizeButton = window.buttons[XCUIIdentifierZoomWindow];
	XCTAssertTrue([resizeButton waitForExistenceWithTimeout:5]);
	[resizeButton click];
	NSPredicate *frameChanged = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return !CGSizeEqualToSize(window.frame.size, originalFrame.size);
	}];
	XCTNSPredicateExpectation *resizeExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:frameChanged object:window];
	[self waitForExpectations:@[ resizeExpectation ] timeout:5];

	XCUIElement *history = [self selectHistoryForCurrentBranch];
	XCTAssertTrue([history.tableRows.firstMatch waitForExistenceWithTimeout:15]);
	XCTAssertTrue(self.app.textViews.firstMatch.exists, @"The restored history view should retain its native diff renderer");
	[self saveWindowScreenshotNamed:@"history-after-hidden-resize"];
}

- (void)testSpaceStagesFilesAndSuccessfulCommitPushesWithoutASecondConfirmation
{
	[self.app terminate];
	NSString *repositoryPath = [self makeDirtyRepositoryFixture];
	[self configureOriginForRepository:repositoryPath];
	NSString *trackingRemotePath = [repositoryPath stringByAppendingString:@"-tracking-remote.git"];
	[self.temporaryRepositoryPaths addObject:trackingRemotePath];
	XCTAssertTrue(([self runGit:@[ @"init", @"--bare", @"--quiet", trackingRemotePath ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"remote", @"add", @"backup", trackingRemotePath ] inDirectory:repositoryPath]));
	XCTAssertTrue(([self runGit:@[ @"push", @"--quiet", @"--set-upstream", @"backup", @"main" ] inDirectory:repositoryPath]));
	NSString *remotePath = trackingRemotePath;
	NSString *initialHead = [self gitOutput:@[ @"rev-parse", @"HEAD" ] inDirectory:repositoryPath];
	NSString *initialRemoteHead = [self gitOutput:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/heads/main" ] inDirectory:repositoryPath];
	XCTAssertEqualObjects(initialHead, initialRemoteHead);

	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : repositoryPath};
	[self launchWithStagingLayout:1];
	[self openStagingViewWaitingForTable:@"UnstagedFiles"];

	XCUIElement *unstagedTable = self.app.tables[@"UnstagedFiles"];
	XCUIElement *stagedTable = self.app.tables[@"StagedFiles"];
	XCTAssertTrue([unstagedTable waitForExistenceWithTimeout:10]);
	XCTAssertTrue([stagedTable waitForExistenceWithTimeout:10]);
	XCUIElement *trackedFile = unstagedTable.staticTexts[@"tracked.swift"];
	XCTAssertTrue([trackedFile waitForExistenceWithTimeout:10]);
	[self.app activate];
	XCUICoordinate *tableOrigin = [unstagedTable coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
	[[tableOrigin coordinateWithOffset:CGVectorMake(50, 10)] click];
	[unstagedTable typeKey:XCUIKeyboardKeySpace modifierFlags:0];
	XCTAssertTrue([stagedTable.staticTexts[@"tracked.swift"] waitForExistenceWithTimeout:10], @"Space should move the selected file to Staged Changes");

	XCUIElement *pushCheckbox = self.app.checkBoxes[@"PushAfterCommit"];
	XCUIElement *remotePopup = self.app.popUpButtons[@"PushRemote"];
	XCTAssertTrue([pushCheckbox waitForExistenceWithTimeout:10]);
	XCTAssertTrue(pushCheckbox.isEnabled);
	XCTAssertTrue([remotePopup waitForExistenceWithTimeout:10]);
	XCTAssertEqualObjects(remotePopup.value, @"backup", @"The checked-out branch's tracking remote should be preferred over origin");
	[pushCheckbox click];
	XCTAssertEqualObjects(pushCheckbox.value, @1);

	XCUIElement *message = self.app.textViews[@"CommitMessage"];
	XCTAssertTrue([message waitForExistenceWithTimeout:10]);
	[self saveWindowScreenshotNamed:@"commit-composer-full-width-message"];
	[message click];
	NSTask *pasteTask = [[NSTask alloc] init];
	pasteTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pbcopy"];
	NSPipe *pasteInput = [NSPipe pipe];
	pasteTask.standardInput = pasteInput;
	XCTAssertTrue([pasteTask launchAndReturnError:nil]);
	[pasteInput.fileHandleForWriting writeData:[@"Commit and push UI test" dataUsingEncoding:NSUTF8StringEncoding]];
	[pasteInput.fileHandleForWriting closeFile];
	[pasteTask waitUntilExit];
	XCTAssertEqual(pasteTask.terminationStatus, 0);
	[message typeKey:@"v" modifierFlags:XCUIKeyModifierCommand];

	NSString *hookPath = [repositoryPath stringByAppendingPathComponent:@".git/hooks/pre-commit"];
	XCTAssertTrue([@"#!/bin/sh\nexit 1\n" writeToFile:hookPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755} ofItemAtPath:hookPath error:nil]);
	[self.app.buttons[@"CommitButton"] click];
	XCUIElement *hookFailure = self.app.staticTexts[@"Commit hook failed"];
	XCTAssertTrue([hookFailure waitForExistenceWithTimeout:10]);
	XCTAssertEqualObjects(pushCheckbox.value, @1, @"A failed commit must leave commit-and-push armed for retry");
	[self saveWindowScreenshotNamed:@"commit-hook-failure-preserves-push-choice"];
	XCTAssertEqualObjects(([self gitOutput:@[ @"rev-parse", @"HEAD" ] inDirectory:repositoryPath]), initialHead);
	XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:hookPath error:nil]);
	XCUIElement *forceCommit = self.app.buttons[@"Force Commit"];
	XCTAssertTrue([forceCommit waitForExistenceWithTimeout:5]);
	[forceCommit click];

	NSPredicate *remoteUpdated = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		NSString *localHead = [self gitOutput:@[ @"rev-parse", @"HEAD" ] inDirectory:repositoryPath];
		NSString *remoteHead = [self gitOutput:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/heads/main" ] inDirectory:repositoryPath];
		return localHead.length > 0 && ![localHead isEqualToString:initialHead] && [localHead isEqualToString:remoteHead];
	}];
	XCTNSPredicateExpectation *pushExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:remoteUpdated object:repositoryPath];
	[self waitForExpectations:@[ pushExpectation ] timeout:20];
	[self saveWindowScreenshotNamed:@"commit-and-push-retry-succeeded"];

	// The successful commit leaves the repository clean, so the staging
	// pane dismisses with the Uncommitted Changes row. Re-dirty the
	// repository and reopen the pane to prove the push choice and remote
	// selection were remembered.
	NSString *followUpPath = [repositoryPath stringByAppendingPathComponent:@"follow-up.txt"];
	XCTAssertTrue([@"follow up\n" writeToFile:followUpPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	[self openStagingViewWaitingForTable:@"UnstagedFiles"];
	pushCheckbox = self.app.checkBoxes[@"PushAfterCommit"];
	XCTAssertTrue([pushCheckbox waitForExistenceWithTimeout:10]);
	NSPredicate *checkboxRemembered = [NSPredicate predicateWithFormat:@"value == 1"];
	XCTNSPredicateExpectation *rememberedExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:checkboxRemembered object:pushCheckbox];
	[self waitForExpectations:@[ rememberedExpectation ] timeout:15];
	remotePopup = self.app.popUpButtons[@"PushRemote"];
	XCTAssertTrue([remotePopup waitForExistenceWithTimeout:10]);
	XCTAssertEqualObjects(remotePopup.value, @"backup", @"Remembering the checkbox should preserve the remote selection");
}

- (void)testPushControlsRefreshForRemotesAndDisableForDetachedHead
{
	[self.app terminate];
	NSString *repositoryPath = [self makeDirtyRepositoryFixture];
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : repositoryPath};
	[self launchWithStagingLayout:0];
	[self openStagingViewWaitingForTable:@"PendingFiles"];

	XCUIElement *pushCheckbox = self.app.checkBoxes[@"PushAfterCommit"];
	XCUIElement *remotePopup = self.app.popUpButtons[@"PushRemote"];
	XCTAssertTrue([pushCheckbox waitForExistenceWithTimeout:10]);
	XCTAssertFalse(pushCheckbox.isEnabled);
	XCTAssertFalse(remotePopup.isEnabled);
	XCTAssertEqualObjects(remotePopup.value, @"No Remotes");

	[self configureOriginForRepository:repositoryPath];
	NSPredicate *remoteAvailable = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return pushCheckbox.isEnabled && remotePopup.isEnabled && [remotePopup.value isEqual:@"origin"];
	}];
	XCTNSPredicateExpectation *remoteExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:remoteAvailable object:pushCheckbox];
	[self waitForExpectations:@[ remoteExpectation ] timeout:15];

	XCTAssertTrue(([self runGit:@[ @"checkout", @"--quiet", @"--detach", @"HEAD" ] inDirectory:repositoryPath]));
	NSPredicate *detachedDisabled = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		return !pushCheckbox.isEnabled && !remotePopup.isEnabled;
	}];
	XCTNSPredicateExpectation *detachedExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:detachedDisabled object:pushCheckbox];
	[self waitForExpectations:@[ detachedExpectation ] timeout:15];
}

- (void)testUncommittedChangesRowAppearsForDirtyRepository
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow]);
	[self selectHistoryForCurrentBranch];

	XCUIElement *workingState = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value == '0 staged, 1 unstaged, 1 untracked'"]].firstMatch;
	XCTAssertTrue([workingState waitForExistenceWithTimeout:15], @"Dirty repositories should pin an Uncommitted Changes row above history");
	[self saveWindowScreenshotNamed:@"uncommitted-changes-row"];
}

- (void)testWorkingStateInsertionPreservesAnOlderCommitSelection
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	XCTAssertTrue(([self runGit:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] inDirectory:fixture]));
	XCTAssertTrue(([self runGit:@[ @"clean", @"-fd", @"--quiet" ] inDirectory:fixture]));
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow]);
	XCUIElement *table = [self selectHistoryForCurrentBranch];
	XCUIElement *initialRow = [table.tableRows containingType:XCUIElementTypeStaticText identifier:@"Initial"].firstMatch;
	XCTAssertTrue([initialRow waitForExistenceWithTimeout:15]);
	[initialRow click];
	XCTAssertTrue(initialRow.isSelected);

	NSString *trackedPath = [fixture stringByAppendingPathComponent:@"tracked.swift"];
	XCTAssertTrue([@"tracked\nsecond\nthird\nexternal edit\n" writeToFile:trackedPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	XCUIElement *workingState = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value == '0 staged, 1 unstaged, 0 untracked'"]].firstMatch;
	XCTAssertTrue([workingState waitForExistenceWithTimeout:15]);
	XCUIElement *currentInitialRow = [table.tableRows containingType:XCUIElementTypeStaticText identifier:@"Initial"].firstMatch;
	XCTAssertTrue(currentInitialRow.isSelected, @"Adding Working State must not jump an older selection to HEAD. %@", table.debugDescription);
	[self saveWindowScreenshotNamed:@"working-state-preserves-old-selection"];
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
	[self.app terminate];
	NSMutableArray<NSString *> *arguments = [self.app.launchArguments mutableCopy];
	arguments[arguments.count - 1] = @"History & Fetch";
	self.app.launchArguments = arguments;
	[self.app launch];
	XCUIElement *historySorting = self.app.checkBoxes[@"Allow commit columns to sort history"];
	[self openPreferencesWaitingForElement:historySorting];
	XCTAssertTrue([self.app.popUpButtons.firstMatch waitForExistenceWithTimeout:5]);
	[self saveWindowScreenshotNamed:@"history-fetch-preferences"];
}

- (void)testGeneralPreferencesOfferRefreshOnFocusWithoutCommitGuides
{
	[self.app terminate];
	NSMutableArray<NSString *> *arguments = [self.app.launchArguments mutableCopy];
	[arguments addObjectsFromArray:@[
		@"-PBUseRepositoryWatcher", @"NO",
		@"-PBRefreshOnApplicationFocus", @"YES"
	]];
	self.app.launchArguments = arguments;
	[self.app launch];

	XCUIElement *continuousWatch = self.app.checkBoxes[@"Watch for changes in repositories"];
	[self openPreferencesWaitingForElement:continuousWatch];
	XCUIElement *refreshOnFocus = self.app.checkBoxes[@"Refresh repositories when GitX regains focus"];
	XCTAssertTrue([refreshOnFocus waitForExistenceWithTimeout:5]);
	XCTAssertFalse([continuousWatch.value boolValue]);
	XCTAssertFalse(continuousWatch.isEnabled);
	XCTAssertTrue([refreshOnFocus.value boolValue]);
	XCTAssertTrue(refreshOnFocus.isEnabled);
	XCTAssertFalse(self.app.checkBoxes[@"Show column guides in commit message"].exists);
	[self saveWindowScreenshotNamed:@"refresh-on-focus-preference"];
}

- (void)testAppearancePreferenceOffersAutomaticLightAndDark
{
	NSArray<NSDictionary<NSString *, NSString *> *> *choices = @[
		@{@"title" : @"Dark", @"value" : @"2"},
		@{@"title" : @"Light", @"value" : @"1"},
		@{@"title" : @"Automatic (System)", @"value" : @"0"},
	];
	for (NSDictionary<NSString *, NSString *> *choice in choices) {
		[self.app terminate];
		NSMutableArray<NSString *> *arguments = [self.app.launchArguments mutableCopy];
		NSString *preferenceFlag = @"-PBAppearancePreference";
		for (NSInteger index = (NSInteger)arguments.count - 1; index >= 0; index--) {
			if (![arguments[index] isEqualToString:preferenceFlag])
				continue;
			[arguments removeObjectAtIndex:(NSUInteger)index];
			if ((NSUInteger)index < arguments.count)
				[arguments removeObjectAtIndex:(NSUInteger)index];
		}
		[arguments addObjectsFromArray:@[ preferenceFlag, choice[@"value"] ]];
		self.app.launchArguments = arguments;
		[self.app launch];

		XCUIElement *appearance = self.app.popUpButtons[@"AppearancePreference"];
		[self openPreferencesWaitingForElement:appearance];
		[self waitForElement:appearance toHaveValue:choice[@"title"] timeout:30];
		[self saveWindowScreenshotNamed:[NSString stringWithFormat:@"appearance-%@", [choice[@"title"] lowercaseString]]];
	}
}

- (void)testDockIconPreferencesOfferFourRobotFaces
{
	[self.app terminate];
	NSMutableArray<NSString *> *arguments = [self.app.launchArguments mutableCopy];
	arguments[arguments.count - 1] = @"Dock Icon";
	self.app.launchArguments = arguments;
	[self.app launch];

	XCUIElement *firstButton = self.app.checkBoxes[@"DockIcon.0"];
	[self openPreferencesWaitingForElement:firstButton];
	NSArray<NSString *> *iconTitles = @[ @"Plus Eyes", @"Bracketed", @"Cursor", @"Mixed Diff" ];
	XCUIElementQuery *iconButtonQuery =
		[self.app.checkBoxes matchingPredicate:[NSPredicate predicateWithFormat:@"title IN %@", iconTitles]];
	NSArray<XCUIElement *> *buttons = iconButtonQuery.allElementsBoundByIndex;
	XCTAssertEqual(buttons.count, (NSUInteger)4, @"Each robot face should be available");
	[self saveWindowScreenshotNamed:@"dock-icon-robot-face-choices"];
}

- (void)testCommitContextMenuScreenshot
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	XCTAssertTrue(([self runGit:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] inDirectory:fixture]));
	XCTAssertTrue(([self runGit:@[ @"clean", @"-fd", @"--quiet" ] inDirectory:fixture]));
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow], @"The context menu requires a repository window");
	XCUIElement *table = [self selectHistoryForCurrentBranch];
	XCUIElement *window = self.app.windows.firstMatch;
	XCUIElement *selectedRow = [table.tableRows containingType:XCUIElementTypeStaticText identifier:@"Third"].firstMatch;
	XCUIElement *clickedRow = [table.tableRows containingType:XCUIElementTypeStaticText identifier:@"Initial"].firstMatch;
	XCTAssertTrue([selectedRow waitForExistenceWithTimeout:15]);
	XCTAssertTrue([clickedRow waitForExistenceWithTimeout:15]);
	[selectedRow click];
	XCTAssertTrue(selectedRow.isSelected);

	[clickedRow rightClick];

	XCUIElement *menu = self.app.menus.firstMatch;
	XCTAssertTrue([menu waitForExistenceWithTimeout:5], @"Right-clicking a commit should open its context menu");
	XCTAssertTrue([menu.menuItems.firstMatch waitForExistenceWithTimeout:5], @"The commit context menu should finish populating");
	XCTAssertTrue(clickedRow.isSelected, @"The context menu and table selection should target the same commit");
	XCTAssertFalse(selectedRow.isSelected);
	[self saveWindowScreenshotNamed:@"commit-context-menu"];

	// Dismiss the menu
	[window typeKey:XCUIKeyboardKeyEscape modifierFlags:0];
}

- (void)testForgeNavigationMenusAndAmbiguousNumberChooserScreenshots
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	XCTAssertTrue(([self runGit:@[ @"remote", @"add", @"origin", @"https://github.com/hbmartin/gitx.git" ]
					inDirectory:fixture]));
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow], @"Forge navigation requires a repository window");
	[self selectHistoryForCurrentBranch];

	XCUIElement *viewRemoteGroup =
		[self.app.toolbars.groups containingType:XCUIElementTypeStaticText
									  identifier:@"View Remote"]
			.firstMatch;
	XCTAssertTrue([viewRemoteGroup waitForExistenceWithTimeout:30],
				  @"The repository toolbar should expose the View Remote item");
	XCUIElement *viewRemote = viewRemoteGroup.menuButtons.firstMatch;
	XCTAssertTrue([viewRemote waitForExistenceWithTimeout:10],
				  @"The repository toolbar should expose the View Remote pull-down");
	[viewRemote click];
	XCUIElement *toolbarMenu = viewRemote.menus.firstMatch;
	XCTAssertTrue([toolbarMenu waitForExistenceWithTimeout:5]);
	XCUIElement *toolbarRepository = toolbarMenu.menuItems[@"GitX.Repository.ForgeLinks.Repository"];
	XCUIElement *toolbarNumber = toolbarMenu.menuItems[@"GitX.Repository.ForgeLinks.PullRequestOrIssue"];
	XCTAssertTrue([toolbarRepository waitForExistenceWithTimeout:5]);
	XCTAssertTrue([toolbarNumber waitForExistenceWithTimeout:5]);
	XCTAssertEqualObjects(toolbarRepository.label, @"View repository on GitHub");
	XCTAssertEqualObjects(toolbarNumber.label, @"Open pull request or issue on GitHub");
	[self saveScreenshotNamed:@"m0-forge-navigation-toolbar-menu"];
	[self.app.windows.firstMatch typeKey:XCUIKeyboardKeyEscape modifierFlags:0];
	NSPredicate *menuDismissed = [NSPredicate predicateWithFormat:@"exists == NO"];
	[self waitForExpectations:@[ [[XCTNSPredicateExpectation alloc] initWithPredicate:menuDismissed object:toolbarMenu] ]
					  timeout:5];

	XCUIElement *repositoryMenuBarItem = self.app.menuBars.menuBarItems[@"Repository"];
	XCTAssertTrue([repositoryMenuBarItem waitForExistenceWithTimeout:5]);
	[repositoryMenuBarItem click];
	XCUIElement *repositoryMenu = repositoryMenuBarItem.menus.firstMatch;
	XCTAssertTrue([repositoryMenu waitForExistenceWithTimeout:5]);
	XCUIElement *repositoryItem = repositoryMenu.menuItems[@"GitX.Repository.ForgeLinks.Repository"];
	XCUIElement *numberItem = repositoryMenu.menuItems[@"GitX.Repository.ForgeLinks.PullRequestOrIssue"];
	XCTAssertTrue([repositoryItem waitForExistenceWithTimeout:5]);
	XCTAssertTrue([numberItem waitForExistenceWithTimeout:5]);
	XCTAssertEqualObjects(repositoryItem.label, @"View repository on GitHub");
	XCTAssertEqualObjects(numberItem.label, @"Open pull request or issue on GitHub");
	[self saveScreenshotNamed:@"m0-forge-navigation-repository-menu"];
	[numberItem click];

	XCUIElement *referenceSheet = self.app.sheets.firstMatch;
	XCUIElement *referencePrompt = referenceSheet.staticTexts[@"Open Pull Request or Issue"];
	XCTAssertTrue([referencePrompt waitForExistenceWithTimeout:5]);
	XCUIElement *referenceField = referenceSheet.textFields[@"GitX.ForgeLinks.NumberedReference"];
	XCTAssertTrue([referenceField waitForExistenceWithTimeout:5]);
	[referenceField click];
	[referenceField typeText:@"#42"];
	XCUIElement *continueButton = referenceSheet.buttons[@"Continue"];
	XCTAssertTrue([continueButton waitForExistenceWithTimeout:5]);
	[continueButton click];

	XCUIElement *choiceSheet = self.app.sheets.firstMatch;
	XCUIElement *choicePrompt = choiceSheet.staticTexts[@"Choose a Destination"];
	XCTAssertTrue([choicePrompt waitForExistenceWithTimeout:5]);
	XCUIElement *destinationChoice = choiceSheet.popUpButtons[@"GitX.ForgeLinks.DestinationChoice"];
	XCTAssertTrue([destinationChoice waitForExistenceWithTimeout:5]);
	[destinationChoice click];
	XCUIElement *pullRequestChoice = destinationChoice.menuItems[@"hbmartin/gitx — Pull Request #42"];
	XCUIElement *issueChoice = destinationChoice.menuItems[@"hbmartin/gitx — Issue #42"];
	XCTAssertTrue([pullRequestChoice waitForExistenceWithTimeout:5]);
	XCTAssertTrue([issueChoice waitForExistenceWithTimeout:5]);
	[self saveScreenshotNamed:@"m0-forge-navigation-number-destination-chooser"];
}

- (void)testManualRefreshUpdatesCheckedOutBranchAndSidebar
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	XCTAssertTrue(([self runGit:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] inDirectory:fixture]));
	XCTAssertTrue(([self runGit:@[ @"clean", @"-fd", @"--quiet" ] inDirectory:fixture]));
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow]);
	XCUIElement *currentBranch = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value == 'main'"]].firstMatch;
	XCTAssertTrue([currentBranch waitForExistenceWithTimeout:10]);
	XCTAssertTrue(([self runGit:@[ @"checkout", @"--quiet", @"-b", @"feature/manual-ui-refresh" ] inDirectory:fixture]));

	XCUIElement *window = self.app.windows.firstMatch;
	[window typeKey:@"r" modifierFlags:XCUIKeyModifierCommand];
	XCUIElement *newBranch = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value ENDSWITH 'manual-ui-refresh'"]].firstMatch;
	XCTAssertTrue([newBranch waitForExistenceWithTimeout:15], @"Manual refresh should reveal externally created branches");
	NSPredicate *updatedTitle = [NSPredicate predicateWithFormat:@"title CONTAINS 'feature/manual-ui-refresh'"];
	XCTNSPredicateExpectation *titleExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:updatedTitle object:window];
	[self waitForExpectations:@[ titleExpectation ] timeout:15];
	[self saveWindowScreenshotNamed:@"manual-refresh-updated-branch"];
}

- (void)testManualRefreshRevealsExternallyConfiguredRemoteBeforeFetch
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	NSString *remotePath = [fixture stringByAppendingString:@"-cli-added-remote.git"];
	[self.temporaryRepositoryPaths addObject:remotePath];
	XCTAssertTrue(([self runGit:@[ @"init", @"--bare", @"--quiet", remotePath ] inDirectory:fixture]));
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow]);

	XCTAssertTrue(([self runGit:@[ @"remote", @"add", @"cli-added", remotePath ] inDirectory:fixture]));
	[self.app.windows.firstMatch typeKey:@"r" modifierFlags:XCUIKeyModifierCommand];
	XCUIElement *remote = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value == 'cli-added'"]].firstMatch;
	XCTAssertTrue([remote waitForExistenceWithTimeout:15], @"Manual refresh should show a configured remote before its first fetch");
	[self saveWindowScreenshotNamed:@"manual-refresh-cli-added-remote"];
}

- (void)testJumpToCheckedOutBranchToolbarButtonAndHotkey
{
	[self.app terminate];
	NSString *fixture = [self makeDirtyRepositoryFixture];
	XCTAssertTrue(([self runGit:@[ @"reset", @"--hard", @"--quiet", @"HEAD" ] inDirectory:fixture]));
	XCTAssertTrue(([self runGit:@[ @"clean", @"-fd", @"--quiet" ] inDirectory:fixture]));
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : fixture};
	[self.app launch];
	XCTAssertTrue([self waitForWindow]);
	[self selectHistoryForCurrentBranch];

	XCUIElement *window = self.app.windows.firstMatch;
	[self.app activate];
	XCUIElement *button = self.app.buttons[@"Current Branch"];
	XCTAssertTrue([button waitForExistenceWithTimeout:30], @"The repository toolbar should expose the checked-out branch action");
	XCTAssertTrue([self.app.menuItems[@"Jump to Checked-Out Branch"] waitForExistenceWithTimeout:5], @"The View menu should expose the checked-out branch hotkey");

	XCTAssertTrue(([self runGit:@[ @"checkout", @"--quiet", @"-b", @"feature/hotkey-jump" ] inDirectory:fixture]));
	[window typeKey:@"j" modifierFlags:(XCUIKeyModifierCommand | XCUIKeyModifierOption)];
	XCUIElement *hotkeyBranch = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value ENDSWITH 'hotkey-jump'"]].firstMatch;
	XCTAssertTrue([hotkeyBranch waitForExistenceWithTimeout:15], @"The hotkey should reveal the externally checked-out branch");
	NSPredicate *hotkeyTitle = [NSPredicate predicateWithFormat:@"title CONTAINS 'feature/hotkey-jump'"];
	[self waitForExpectations:@[ [[XCTNSPredicateExpectation alloc] initWithPredicate:hotkeyTitle object:window] ] timeout:15];

	XCTAssertTrue(([self runGit:@[ @"checkout", @"--quiet", @"-b", @"feature/button-jump" ] inDirectory:fixture]));
	[button click];
	XCUIElement *buttonBranch = [self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"value ENDSWITH 'button-jump'"]].firstMatch;
	XCTAssertTrue([buttonBranch waitForExistenceWithTimeout:15], @"The toolbar button should reveal the externally checked-out branch");
	NSPredicate *buttonTitle = [NSPredicate predicateWithFormat:@"title CONTAINS 'feature/button-jump'"];
	[self waitForExpectations:@[ [[XCTNSPredicateExpectation alloc] initWithPredicate:buttonTitle object:window] ] timeout:15];
	[self saveWindowScreenshotNamed:@"jump-to-checked-out-branch"];
}

@end

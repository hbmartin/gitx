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
- (void)openPreferences;
- (void)openStagingView;
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
		@"-NSAutomaticWindowAnimationsEnabled", @"NO"
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

- (void)openPreferences
{
	XCTAssertTrue([self waitForWindow], @"Preferences require the application to finish launching");
	[self.app activate];
	[self.app.windows.firstMatch typeKey:@"," modifierFlags:XCUIKeyModifierCommand];
	XCTAssertTrue([self.app.dialogs.firstMatch waitForExistenceWithTimeout:5]);
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
	XCTAssertTrue([branch waitForExistenceWithTimeout:10], @"The repository's current branch should be visible in the sidebar");
	[branch click];
	XCUIElement *table = self.app.tables[@"CommitList"];
	XCTAssertTrue([table waitForExistenceWithTimeout:15], @"Selecting the current branch should open history");
	return table;
}

- (void)openStagingView
{
	XCTAssertTrue([self waitForWindow], @"Staging requires a repository window");
	XCUIElement *sidebar = self.app.outlines[@"RepositorySidebar"];
	XCTAssertTrue([sidebar waitForExistenceWithTimeout:10], @"The repository sidebar should be accessible");
	XCUIElement *stageItem = sidebar.staticTexts[@"Stage"];
	XCTAssertTrue([stageItem waitForExistenceWithTimeout:10], @"The Stage item should be visible in the sidebar");
	[stageItem click];
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
	[self openStagingView];

	[self saveWindowScreenshotNamed:@"staging-view"];
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
	[self.app launch];
	[self openStagingView];

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
	[self.app.buttons[@"Commit"] click];
	XCUIElement *hookFailure = self.app.staticTexts[@"Commit hook failed"];
	XCTAssertTrue([hookFailure waitForExistenceWithTimeout:10]);
	XCTAssertEqualObjects(pushCheckbox.value, @1, @"A failed commit must leave commit-and-push armed for retry");
	XCTAssertEqualObjects(([self gitOutput:@[ @"rev-parse", @"HEAD" ] inDirectory:repositoryPath]), initialHead);
	XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:hookPath error:nil]);
	[self.app.buttons[@"OK"] click];

	NSString *postCommitHookPath = [repositoryPath stringByAppendingPathComponent:@".git/hooks/post-commit"];
	XCTAssertTrue([@"#!/bin/sh\nexit 1\n" writeToFile:postCommitHookPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755} ofItemAtPath:postCommitHookPath error:nil]);
	[self.app.buttons[@"Commit"] click];
	NSPredicate *checkboxReset = [NSPredicate predicateWithFormat:@"value == 0"];
	XCTNSPredicateExpectation *resetExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:checkboxReset object:pushCheckbox];
	[self waitForExpectations:@[ resetExpectation ] timeout:15];

	NSPredicate *remoteUpdated = [NSPredicate predicateWithBlock:^BOOL(__unused id object, __unused NSDictionary *bindings) {
		NSString *localHead = [self gitOutput:@[ @"rev-parse", @"HEAD" ] inDirectory:repositoryPath];
		NSString *remoteHead = [self gitOutput:@[ @"--git-dir", remotePath, @"rev-parse", @"refs/heads/main" ] inDirectory:repositoryPath];
		return localHead.length > 0 && ![localHead isEqualToString:initialHead] && [localHead isEqualToString:remoteHead];
	}];
	XCTNSPredicateExpectation *pushExpectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:remoteUpdated object:repositoryPath];
	[self waitForExpectations:@[ pushExpectation ] timeout:20];
	XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:postCommitHookPath error:nil]);
	XCTAssertEqualObjects(remotePopup.value, @"backup", @"Resetting the checkbox should preserve the remote selection");
}

- (void)testPushControlsRefreshForRemotesAndDisableForDetachedHead
{
	[self.app terminate];
	NSString *repositoryPath = [self makeDirtyRepositoryFixture];
	self.app.launchEnvironment = @{@"GITX_UITEST_REPO" : repositoryPath};
	[self.app launch];
	[self openStagingView];

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
	[self openPreferences];
	XCUIElement *preferences = self.app.dialogs.firstMatch;
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

- (void)testGeneralPreferencesOfferRefreshOnFocus
{
	[self openPreferences];
	XCUIElement *preferences = self.app.dialogs.firstMatch;

	XCUIElement *generalPane = preferences.toolbars.buttons[@"General"];
	XCTAssertTrue([generalPane waitForExistenceWithTimeout:5]);
	[generalPane click];

	XCUIElement *continuousWatch = preferences.checkBoxes[@"Watch for changes in repositories"];
	XCUIElement *refreshOnFocus = preferences.checkBoxes[@"Refresh repositories when GitX regains focus"];
	XCTAssertTrue([continuousWatch waitForExistenceWithTimeout:5]);
	XCTAssertTrue([refreshOnFocus waitForExistenceWithTimeout:5]);
	BOOL watchedOriginally = [continuousWatch.value boolValue];
	BOOL focusedOriginally = [refreshOnFocus.value boolValue];

	@try {
		if (watchedOriginally) {
			[continuousWatch click];
		}
		XCTAssertTrue(refreshOnFocus.isEnabled);
		if (![refreshOnFocus.value boolValue]) {
			[refreshOnFocus click];
		}
		XCTAssertFalse(continuousWatch.isEnabled);
		[self saveWindowScreenshotNamed:@"refresh-on-focus-preference"];
	} @finally {
		if ([refreshOnFocus.value boolValue] != focusedOriginally) {
			[refreshOnFocus click];
		}
		if ([continuousWatch.value boolValue] != watchedOriginally) {
			[continuousWatch click];
		}
	}
}

- (void)testAppearancePreferenceOffersAutomaticLightAndDark
{
	[self openPreferences];
	XCUIElement *preferences = self.app.dialogs.firstMatch;

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
			[self waitForElement:appearance toHaveValue:title timeout:5];
			[self saveWindowScreenshotNamed:[NSString stringWithFormat:@"appearance-%@", title.lowercaseString]];
		}
	} @finally {
		if (originalValue.length && ![appearance.value isEqual:originalValue]) {
			[appearance click];
			XCUIElement *originalChoice = self.app.menuItems[originalValue];
			XCTAssertTrue([originalChoice waitForExistenceWithTimeout:5]);
			[originalChoice click];
			[self waitForElement:appearance toHaveValue:originalValue timeout:5];
		}
	}
}

- (void)testCommitContextMenuScreenshot
{
	XCTAssertTrue([self waitForWindow], @"The context menu requires a repository window");
	XCUIElement *table = [self selectHistoryForCurrentBranch];
	XCUIElement *window = self.app.windows.firstMatch;
	XCUIElement *firstRow = [table.tableRows elementBoundByIndex:0];
	XCTAssertTrue([firstRow waitForExistenceWithTimeout:15], @"The commit list should contain a row");

	// Right-click to open the context menu
	[firstRow rightClick];

	XCUIElement *menu = self.app.menus.firstMatch;
	XCTAssertTrue([menu waitForExistenceWithTimeout:5], @"Right-clicking a commit should open its context menu");
	XCTAssertTrue([menu.menuItems.firstMatch waitForExistenceWithTimeout:5], @"The commit context menu should finish populating");
	[self saveWindowScreenshotNamed:@"commit-context-menu"];

	// Dismiss the menu
	[window typeKey:XCUIKeyboardKeyEscape modifierFlags:0];
}

@end

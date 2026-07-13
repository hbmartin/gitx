#import <XCTest/XCTest.h>

#import "PBGitDefaults.h"
#import "PBHistoryArrayController.h"
#import "PBHighlighting.h"
#import "PBNativeContentView.h"
#import "PBTask.h"

@interface GitXFeatureTests : XCTestCase
@end

@interface PBNativeContentView (GitXFeatureTests)
- (nullable NSString *)patchWithFileHeader:(NSArray<NSString *> *)fileHeader
							 hunkLines:(NSArray<NSString *> *)hunkLines
						selectedIndexes:(NSIndexSet *)selectedIndexes
							  reverse:(BOOL)reverse;
@end

@implementation GitXFeatureTests

- (void)setUp
{
	[super setUp];
	[PBGitDefaults setHistoryColumnSortingEnabled:YES];
	[PBGitDefaults setAutoFetchScope:PBAutoFetchScopeNone];
	[PBGitDefaults setAutoFetchIntervalMinutes:15];
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

- (void)testHistoryControllerPinsWorkingStateAboveSortedCommits
{
	PBHistoryArrayController *controller = [[PBHistoryArrayController alloc] initWithContent:@[
		@{ @"subject" : @"B" }, @{ @"subject" : @"A" }
	]];
	NSObject *workingState = [[NSObject alloc] init];
	controller.pinnedObject = workingState;
	controller.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"subject" ascending:YES] ];
	NSArray *arranged = controller.arrangedObjects;
	XCTAssertEqual(arranged.firstObject, workingState);
	XCTAssertEqualObjects(arranged[1][@"subject"], @"A");
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
	[view showSourceSections:@[@{ PBNativeSectionPathKey : @"Example.swift", PBNativeSectionTextKey : @"let value = 42\n" }]];
	XCTAssertFalse(view.textView.isEditable);
	XCTAssertTrue(view.textView.isSelectable);
}

- (void)testTaskAppliesEnvironmentConfiguredAfterCreation
{
	PBTask *task = [PBTask taskWithLaunchPath:@"/usr/bin/env" arguments:@[] inDirectory:nil];
	task.additionalEnvironment = @{ @"GITX_TEST_ENVIRONMENT" : @"present" };
	NSError *error = nil;
	XCTAssertTrue([task launchTask:&error], @"%@", error);
	XCTAssertTrue([task.standardOutputString containsString:@"GITX_TEST_ENVIRONMENT=present"]);
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

@end

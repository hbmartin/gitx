#import <XCTest/XCTest.h>
#import <ObjectiveGit/GTOID.h>
#import "PBGitRevisionCell.h"
#import "PBGitCommit.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"
#import "PBGraphCellInfo.h"

// C graph buffers and private drawing entry points remain Objective-C test
// surfaces rather than becoming application API solely for Swift tests.
@interface PBGitRevisionCell (WorktreeCharacterization)
- (NSColor *)colorForRef:(PBGitRef *)ref;
+ (NSArray<NSColor *> *)laneColors;
@end

@interface WorktreeGraphRepository : PBGitRepository
@property PBGitRevSpecifier *testHead;
@property GTOID *testOID;
@end
@implementation WorktreeGraphRepository
- (PBGitRevSpecifier *)headRef
{
	return self.testHead;
}
- (GTOID *)headOID
{
	return self.testOID;
}
@end

@interface WorktreeGraphController : PBGitHistoryController
@property BOOL nonlinear;
@end
@implementation WorktreeGraphController
- (BOOL)hasNonlinearPath
{
	return self.nonlinear;
}
@end

@interface WorktreeGraphCommit : PBGitCommit
@property PBGitRepository *testRepository;
@property GTOID *testOID;
@end
@implementation WorktreeGraphCommit
- (PBGitRepository *)repository
{
	return self.testRepository;
}
- (GTOID *)OID
{
	return self.testOID;
}
@end

@interface WorktreeRevisionCharacterizationTests : XCTestCase
@end
@implementation WorktreeRevisionCharacterizationTests

- (void)testReferenceColorsAndCurrentBranchPriority
{
	WorktreeGraphRepository *repository = [WorktreeGraphRepository new];
	repository.testHead = [[PBGitRevSpecifier alloc] initWithRef:[PBGitRef refFromString:@"refs/heads/main"]];
	WorktreeGraphController *controller = [[WorktreeGraphController alloc] initWithRepository:repository superController:nil];
	PBGitRevisionCell *cell = [[PBGitRevisionCell alloc] initWithFrame:NSMakeRect(0, 0, 500, 24)];
	[cell setValue:controller forKey:@"controller"];
	NSArray *refs = @[ @"refs/heads/main", @"refs/heads/other", @"refs/remotes/origin/main", @"refs/tags/v1" ];
	NSArray *components = @[ @[ @252, @166, @79 ], @[ @154, @226, @132 ], @[ @162, @207, @239 ], @[ @252, @237, @111 ] ];
	for (NSUInteger index = 0; index < refs.count; index++) {
		NSColor *color = [[cell colorForRef:[PBGitRef refFromString:refs[index]]] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
		XCTAssertEqualWithAccuracy(color.redComponent, [components[index][0] doubleValue] / 256, 0.00001);
		XCTAssertEqualWithAccuracy(color.greenComponent, [components[index][1] doubleValue] / 256, 0.00001);
		XCTAssertEqualWithAccuracy(color.blueComponent, [components[index][2] doubleValue] / 256, 0.00001);
	}
	XCTAssertEqualObjects([cell colorForRef:[PBGitRef refFromString:@"unknown"]], NSColor.yellowColor);
	[cell setValue:nil forKey:@"controller"];
	XCTAssertNotNil([cell colorForRef:[PBGitRef refFromString:@"refs/heads/main"]]);
}

- (void)testGraphRenderingLayoutAndReferenceHitBoundaries
{
	WorktreeGraphRepository *repository = [WorktreeGraphRepository new];
	repository.refs = [NSMutableDictionary new];
	WorktreeGraphController *controller = [[WorktreeGraphController alloc] initWithRepository:repository superController:nil];
	WorktreeGraphCommit *commit = [WorktreeGraphCommit new];
	commit.testRepository = repository;
	commit.testOID = [GTOID oidWithSHA:@"1111111111111111111111111111111111111111"];
	struct PBGitGraphLine *lines = calloc(4, sizeof(struct PBGitGraphLine));
	lines[0] = (struct PBGitGraphLine){.upper = 0, .from = 1, .to = 1, .colorIndex = 0};
	lines[1] = (struct PBGitGraphLine){.upper = -1, .from = 1, .to = 1, .colorIndex = 1};
	lines[2] = (struct PBGitGraphLine){.upper = 0, .from = 0, .to = 1, .colorIndex = 2};
	lines[3] = (struct PBGitGraphLine){.upper = -1, .from = 2, .to = 1, .colorIndex = 3};
	PBGraphCellInfo *info = [[PBGraphCellInfo alloc] initWithPosition:1 andLines:lines];
	info.numColumns = 3;
	info.nLines = 4;
	commit.lineInfo = info;
	commit.refs = [NSMutableArray arrayWithObjects:[PBGitRef refFromString:@"refs/heads/topic"], [PBGitRef refFromString:@"refs/tags/v1"], nil];
	PBGitRevisionCell *cell = [[PBGitRevisionCell alloc] initWithFrame:NSMakeRect(0, 0, 500, 24)];
	NSTextField *text = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 100, 18)];
	[cell addSubview:text];
	cell.textField = text;
	[cell setValue:controller forKey:@"controller"];
	cell.objectValue = commit;
	XCTAssertEqual(cell.objectValue, commit);
	XCTAssertTrue(cell.flipped);
	XCTAssertEqual([PBGitRevisionCell laneColors].count, (NSUInteger)8);
	NSImage *canvas = [[NSImage alloc] initWithSize:cell.bounds.size];
	[canvas lockFocus];
	for (NSNumber *sign in @[ @0, @('<'), @('>') ]) {
		info.sign = sign.charValue;
		[cell drawRect:cell.bounds];
	}
	repository.testOID = commit.testOID;
	info.sign = 0;
	[cell drawRect:cell.bounds];
	controller.nonlinear = YES;
	[cell drawRect:cell.bounds];
	[cell layout];
	[canvas unlockFocus];
	controller.nonlinear = NO;
	[cell layout];
	NSRect label = [cell rectAtIndex:0];
	XCTAssertEqual([cell indexAtX:NSMinX(label)], 0);
	XCTAssertEqual([cell indexAtX:NSMaxX(label)], 0);
	XCTAssertEqual([cell indexAtX:-1], -1);
	XCTAssertEqual([cell indexAtX:9999], -1);
	controller.nonlinear = YES;
	XCTAssertEqual([cell indexAtX:NSMidX([cell rectAtIndex:0])], 0);
	cell.frame = NSMakeRect(0, 0, 1, 24);
	[cell layout];
	[commit.refs removeAllObjects];
	cell.objectValue = nil;
	[cell layout];
	[canvas lockFocus];
	[cell drawRect:cell.bounds];
	[canvas unlockFocus];
	XCTAssertNil(cell.objectValue);
	XCTAssertEqual([cell indexAtX:0], -1);
}
@end

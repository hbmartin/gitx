#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBRepositoryRefreshCoordinator : NSObject
- (instancetype)initWithDelay:(NSTimeInterval)delay
			  deliveryHandler:(void (^)(NSUInteger eventType, NSArray<NSString *> *paths))deliveryHandler;
- (void)recordEventType:(NSUInteger)eventType paths:(NSArray<NSString *> *)paths;
- (void)cancel;
@end

@interface PBRepositoryRefreshPolicy : NSObject
+ (BOOL)shouldRefreshAfterApplicationActivation;
+ (BOOL)shouldRefreshStatCacheAfterApplicationActivation;
@end

@interface PBRepositoryFocusRefreshTracker : NSObject
- (BOOL)shouldRefreshForSnapshotComponents:(NSArray<NSData *> *)snapshotComponents;
- (void)reset;
@end

@interface RepositoryRefreshCoordinatorTests : XCTestCase
@end

NS_ASSUME_NONNULL_END

@implementation RepositoryRefreshCoordinatorTests

- (void)testTrailingDebounceUnionsEventTypesDeduplicatesPathsAndDeliversOnMainThread
{
	XCTestExpectation *delivered = [self expectationWithDescription:@"Refresh batch delivered"];
	__block NSUInteger deliveryCount = 0;
	PBRepositoryRefreshCoordinator *coordinator =
		[[PBRepositoryRefreshCoordinator alloc] initWithDelay:0.05
											  deliveryHandler:^(NSUInteger eventType, NSArray<NSString *> *paths) {
												  deliveryCount += 1;
												  XCTAssertTrue(NSThread.isMainThread);
												  XCTAssertEqual(eventType, (NSUInteger)6);
												  XCTAssertEqualObjects(paths, (@[ @"/repo/.git/HEAD", @"/repo/shared", @"/repo/work.swift" ]));
												  [delivered fulfill];
											  }];

	[coordinator recordEventType:2 paths:@[ @"/repo/.git/HEAD", @"/repo/shared" ]];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[coordinator recordEventType:4 paths:@[ @"/repo/work.swift", @"/repo/shared" ]];
	});

	[self waitForExpectations:@[ delivered ] timeout:1.0];
	XCTAssertEqual(deliveryCount, (NSUInteger)1);
}

- (void)testCancellationDropsPendingBatch
{
	XCTestExpectation *delivery = [self expectationWithDescription:@"Cancelled batch is not delivered"];
	delivery.inverted = YES;
	PBRepositoryRefreshCoordinator *coordinator =
		[[PBRepositoryRefreshCoordinator alloc] initWithDelay:0.02
											  deliveryHandler:^(NSUInteger eventType, NSArray<NSString *> *paths) {
												  [delivery fulfill];
											  }];

	[coordinator recordEventType:4 paths:@[ @"/repo/work.swift" ]];
	[coordinator cancel];
	[self waitForExpectations:@[ delivery ] timeout:0.1];
}

- (void)testCancellationDropsBatchAwaitingMainQueueCallback
{
	XCTestExpectation *delivery = [self expectationWithDescription:@"Queued callback is not delivered"];
	delivery.inverted = YES;
	PBRepositoryRefreshCoordinator *coordinator =
		[[PBRepositoryRefreshCoordinator alloc] initWithDelay:0.01
											  deliveryHandler:^(NSUInteger eventType, NSArray<NSString *> *paths) {
												  [delivery fulfill];
											  }];
	dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);

	[coordinator recordEventType:4 paths:@[ @"/repo/work.swift" ]];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
				   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
					   [coordinator cancel];
					   dispatch_semaphore_signal(cancelled);
				   });

	long waitResult = dispatch_semaphore_wait(cancelled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
	XCTAssertEqual(waitResult, 0L);
	[self waitForExpectations:@[ delivery ] timeout:0.1];
}

- (void)testEventsRecordedDuringDeliveryProduceOneTrailingReplay
{
	XCTestExpectation *delivered = [self expectationWithDescription:@"Initial and replay batches delivered"];
	delivered.expectedFulfillmentCount = 2;
	__block NSUInteger deliveryCount = 0;
	__block PBRepositoryRefreshCoordinator *coordinator;
	coordinator =
		[[PBRepositoryRefreshCoordinator alloc] initWithDelay:0.01
											  deliveryHandler:^(NSUInteger eventType, NSArray<NSString *> *paths) {
												  deliveryCount += 1;
												  if (deliveryCount == 1) {
													  XCTAssertEqual(eventType, (NSUInteger)2);
													  [coordinator recordEventType:4 paths:@[ @"/repo/a" ]];
													  [coordinator recordEventType:8 paths:@[ @"/repo/a", @"/repo/b" ]];
												  } else {
													  XCTAssertEqual(eventType, (NSUInteger)12);
													  XCTAssertEqualObjects(paths, (@[ @"/repo/a", @"/repo/b" ]));
												  }
												  [delivered fulfill];
											  }];
	[coordinator recordEventType:2 paths:@[ @"/repo/.git/HEAD" ]];
	[self waitForExpectations:@[ delivered ] timeout:1.0];
	XCTAssertEqual(deliveryCount, (NSUInteger)2);
	coordinator = nil;
}

- (void)testEmptyEventTypeDoesNotScheduleDelivery
{
	XCTestExpectation *delivery = [self expectationWithDescription:@"Empty event is ignored"];
	delivery.inverted = YES;
	PBRepositoryRefreshCoordinator *coordinator =
		[[PBRepositoryRefreshCoordinator alloc] initWithDelay:0.01
											  deliveryHandler:^(NSUInteger eventType, NSArray<NSString *> *paths) {
												  [delivery fulfill];
											  }];

	[coordinator recordEventType:0 paths:@[ @"/repo/ignored" ]];
	[self waitForExpectations:@[ delivery ] timeout:0.1];
}

@end

@interface RepositoryRefreshPolicyTests : XCTestCase
@end

@implementation RepositoryRefreshPolicyTests

- (void)testRefreshOnFocusPolicyIsOptIn
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	NSString *key = @"PBRefreshOnApplicationFocus";
	id previousValue = [defaults objectForKey:key];

	[defaults removeObjectForKey:key];
	XCTAssertFalse([PBRepositoryRefreshPolicy shouldRefreshAfterApplicationActivation]);
	XCTAssertTrue([PBRepositoryRefreshPolicy shouldRefreshStatCacheAfterApplicationActivation]);
	[defaults setBool:YES forKey:key];
	XCTAssertTrue([PBRepositoryRefreshPolicy shouldRefreshAfterApplicationActivation]);
	XCTAssertFalse([PBRepositoryRefreshPolicy shouldRefreshStatCacheAfterApplicationActivation]);
	[defaults setBool:NO forKey:key];
	XCTAssertFalse([PBRepositoryRefreshPolicy shouldRefreshAfterApplicationActivation]);
	XCTAssertTrue([PBRepositoryRefreshPolicy shouldRefreshStatCacheAfterApplicationActivation]);

	if (previousValue) {
		[defaults setObject:previousValue forKey:key];
	} else {
		[defaults removeObjectForKey:key];
	}
}

- (void)testFocusRefreshTrackerOnlyRefreshesForChangedSnapshots
{
	PBRepositoryFocusRefreshTracker *tracker = [[PBRepositoryFocusRefreshTracker alloc] init];
	NSArray<NSData *> *initialSnapshot = @[ [@"a" dataUsingEncoding:NSUTF8StringEncoding], [@"bc" dataUsingEncoding:NSUTF8StringEncoding] ];
	NSArray<NSData *> *changedAtComponentBoundary = @[ [@"ab" dataUsingEncoding:NSUTF8StringEncoding], [@"c" dataUsingEncoding:NSUTF8StringEncoding] ];

	XCTAssertFalse([tracker shouldRefreshForSnapshotComponents:initialSnapshot]);
	XCTAssertFalse([tracker shouldRefreshForSnapshotComponents:initialSnapshot]);
	XCTAssertTrue([tracker shouldRefreshForSnapshotComponents:changedAtComponentBoundary]);
	XCTAssertFalse([tracker shouldRefreshForSnapshotComponents:changedAtComponentBoundary]);

	[tracker reset];
	XCTAssertFalse([tracker shouldRefreshForSnapshotComponents:initialSnapshot]);
}

@end

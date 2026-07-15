#import <XCTest/XCTest.h>
#import <ObjectiveGit/GTRepository.h>

#import "PBGitRepository.h"
#import "PBGitRepositoryWatcher.h"
#import "PBTask.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBRepositoryRefreshCoordinator : NSObject
- (instancetype)initWithDelay:(NSTimeInterval)delay
			  deliveryHandler:(void (^)(NSUInteger eventType, NSArray<NSString *> *paths))deliveryHandler;
- (void)recordEventType:(NSUInteger)eventType paths:(NSArray<NSString *> *)paths;
- (void)cancel;
@end

@interface PBGitRepositoryWatcherTests : XCTestCase

@property (nonatomic, strong) NSURL *repositoryURL;
@property (nonatomic, strong) PBGitRepository *repository;
@property (nonatomic, strong, nullable) id previousUseWatcherPreference;
@property (nonatomic, strong, nullable) id previousFocusRefreshPreference;

@end


@implementation PBGitRepositoryWatcherTests

- (void)setUp
{
	[super setUp];

	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	self.previousUseWatcherPreference = [defaults objectForKey:@"PBUseRepositoryWatcher"];
	self.previousFocusRefreshPreference = [defaults objectForKey:@"PBRefreshOnApplicationFocus"];
	[defaults setBool:YES forKey:@"PBUseRepositoryWatcher"];
	[defaults setBool:NO forKey:@"PBRefreshOnApplicationFocus"];

	self.repositoryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
													stringByAppendingPathComponent:[NSString stringWithFormat:@"GitXWatcherTests-%@", NSUUID.UUID.UUIDString]]
									isDirectory:YES];
	NSError *error = nil;
	NSString *gitOutput = [PBTask outputForCommand:@"/usr/bin/git"
										 arguments:@[ @"init", @"--quiet", self.repositoryURL.path ]
									   inDirectory:nil
											 error:&error];
	XCTAssertNotNil(gitOutput, @"%@", error);
	NSString *trackedPath = [self.repositoryURL.path stringByAppendingPathComponent:@"changed.txt"];
	XCTAssertTrue([@"initial\n" writeToFile:trackedPath atomically:NO encoding:NSUTF8StringEncoding error:&error], @"%@", error);
	gitOutput = [PBTask outputForCommand:@"/usr/bin/git"
							   arguments:@[ @"add", @"changed.txt" ]
							 inDirectory:self.repositoryURL.path
								   error:&error];
	XCTAssertNotNil(gitOutput, @"%@", error);
	gitOutput = [PBTask outputForCommand:@"/usr/bin/git"
							   arguments:@[ @"-c", @"user.name=GitX Tests", @"-c", @"user.email=gitx-tests@example.com", @"commit", @"--quiet", @"-m", @"Initial" ]
							 inDirectory:self.repositoryURL.path
								   error:&error];
	XCTAssertNotNil(gitOutput, @"%@", error);
	self.repository = [[PBGitRepository alloc] initWithURL:self.repositoryURL error:&error];
	XCTAssertNotNil(self.repository, @"%@", error);
}

- (void)tearDown
{
	self.repository = nil;
	[[NSFileManager defaultManager] removeItemAtURL:self.repositoryURL error:nil];

	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if (self.previousUseWatcherPreference) {
		[defaults setObject:self.previousUseWatcherPreference forKey:@"PBUseRepositoryWatcher"];
	} else {
		[defaults removeObjectForKey:@"PBUseRepositoryWatcher"];
	}
	if (self.previousFocusRefreshPreference) {
		[defaults setObject:self.previousFocusRefreshPreference forKey:@"PBRefreshOnApplicationFocus"];
	} else {
		[defaults removeObjectForKey:@"PBRefreshOnApplicationFocus"];
	}

	[super tearDown];
}

- (void)testWorkingTreeEditDeliversRepositoryNotificationOnMainThread
{
	XCTestExpectation *delivered = [self expectationWithDescription:@"Watcher delivered working-tree edit"];
	NSString *changedPath = [self.repositoryURL.path stringByAppendingPathComponent:@"changed.txt"];
	id notificationToken = [[NSNotificationCenter defaultCenter]
		addObserverForName:PBGitRepositoryEventNotification
					object:self.repository
					 queue:NSOperationQueue.mainQueue
				usingBlock:^(NSNotification *notification) {
					XCTAssertTrue(NSThread.isMainThread);
					NSUInteger eventType = [notification.userInfo[kPBGitRepositoryEventTypeUserInfoKey] unsignedIntegerValue];
					XCTAssertNotEqual(eventType & PBGitRepositoryWatcherEventTypeWorkingDirectory, (NSUInteger)0);
					NSArray<NSString *> *paths = notification.userInfo[kPBGitRepositoryEventPathsUserInfoKey];
					XCTAssertTrue([paths containsObject:changedPath]);
					[delivered fulfill];
				}];

	NSError *error = nil;
	NSString *output = [PBTask outputForCommand:@"/bin/sh"
									  arguments:@[ @"-c", @"printf 'changed\\n' > changed.txt" ]
									inDirectory:self.repositoryURL.path
										  error:&error];
	XCTAssertNotNil(output, @"%@", error);
	[self waitForExpectations:@[ delivered ] timeout:5.0];
	[[NSNotificationCenter defaultCenter] removeObserver:notificationToken];
}

@end

@interface PBRepositoryRefreshPolicy : NSObject
+ (BOOL)shouldRefreshAfterApplicationActivation;
+ (BOOL)shouldRefreshStatCacheAfterApplicationActivation;
@end

@interface PBRepositoryFocusRefreshTracker : NSObject
- (BOOL)shouldRefreshForSnapshotComponents:(NSArray<NSData *> *)snapshotComponents;
- (void)reset;
@end

@interface NSObject (PBRefreshCoalescerTesting)
- (instancetype)initWithDeliveryHandler:(void (^)(void))deliveryHandler;
- (void)requestRefresh;
- (void)cancel;
@end

@interface RepositoryRefreshCoordinatorTests : XCTestCase
@end

@interface RefreshCoalescerTests : XCTestCase
@end

@implementation RefreshCoalescerTests

- (void)testBurstOfRefreshRequestsDeliversOnce
{
	Class coalescerClass = NSClassFromString(@"PBRefreshCoalescer");
	XCTAssertNotNil(coalescerClass);
	if (!coalescerClass) return;
	XCTestExpectation *delivered = [self expectationWithDescription:@"Refresh delivered"];
	__block NSUInteger deliveryCount = 0;
	id coalescer = [[coalescerClass alloc] initWithDeliveryHandler:^{
		deliveryCount++;
		[delivered fulfill];
	}];

	[coalescer requestRefresh];
	[coalescer requestRefresh];
	[coalescer requestRefresh];

	[self waitForExpectations:@[ delivered ] timeout:1.0];
	XCTAssertEqual(deliveryCount, (NSUInteger)1);
}

- (void)testRequestDuringDeliveryProducesOneTrailingRefresh
{
	Class coalescerClass = NSClassFromString(@"PBRefreshCoalescer");
	XCTAssertNotNil(coalescerClass);
	if (!coalescerClass) return;
	XCTestExpectation *delivered = [self expectationWithDescription:@"Initial and trailing refresh delivered"];
	delivered.expectedFulfillmentCount = 2;
	__block NSUInteger deliveryCount = 0;
	__block id coalescer = nil;
	coalescer = [[coalescerClass alloc] initWithDeliveryHandler:^{
		deliveryCount++;
		if (deliveryCount == 1) {
			[coalescer requestRefresh];
			[coalescer requestRefresh];
		}
		[delivered fulfill];
	}];

	[coalescer requestRefresh];

	[self waitForExpectations:@[ delivered ] timeout:1.0];
	XCTAssertEqual(deliveryCount, (NSUInteger)2);
}

- (void)testCancellationDropsPendingRefresh
{
	Class coalescerClass = NSClassFromString(@"PBRefreshCoalescer");
	XCTAssertNotNil(coalescerClass);
	if (!coalescerClass) return;
	XCTestExpectation *delivered = [self expectationWithDescription:@"Cancelled refresh is not delivered"];
	delivered.inverted = YES;
	id coalescer = [[coalescerClass alloc] initWithDeliveryHandler:^{
		[delivered fulfill];
	}];

	[coalescer requestRefresh];
	[coalescer cancel];

	[self waitForExpectations:@[ delivered ] timeout:0.1];
}

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

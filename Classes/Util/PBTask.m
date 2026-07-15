//
//  PBTask.m
//  GitX
//
//  Created by Etienne on 22/02/2017.
//
//

#import "PBTask.h"
#import "PBProcessEnvironment.h"

NSString *const PBTaskErrorDomain = @"PBTaskErrorDomain";
NSString *const PBTaskUnderlyingExceptionKey = @"PBTaskUnderlyingExceptionKey";
NSString *const PBTaskTerminationStatusKey = @"PBTaskTerminationStatusKey";
NSString *const PBTaskTerminationOutputKey = @"PBTaskTerminationOutputKey";

const BOOL PBTaskDebugEnable = NO;
static const NSTimeInterval PBTaskOutputDrainGrace = 0.1;

#define PBTaskLog(...)                             \
	do {                                           \
		if (PBTaskDebugEnable) NSLog(__VA_ARGS__); \
	} while (0)

@interface PBTask ()

@property (retain) NSTask *task;
@property (retain) NSData *standardOutputData;
@property (retain) NSMutableData *standardOutputBuffer;
@property (retain) NSPipe *outputPipe;
@property (retain) NSPipe *inputPipe;
@property (strong) dispatch_queue_t stateQueue;
@property (strong) dispatch_queue_t callbackQueue;
@property (copy) void (^resultHandler)(NSData *_Nullable data, NSError *_Nullable error);
@property (strong) PBTask *operationRetainer;
@property BOOL cancellationRequested;
@property BOOL operationStarted;
@property BOOL taskFinished;
@property BOOL outputFinished;
@property BOOL operationFinished;
@property BOOL outputReaderStopped;
@property BOOL outputDrainScheduled;
@property BOOL outputDrainExpired;
@property NSUInteger outputReadsInFlight;
@property BOOL outputHandleClosePending;
@property BOOL outputHandleClosed;
@property NSTaskTerminationReason terminationReason;
@property int terminationStatus;
@property (retain) NSError *forcedError;

- (void)stopOutputReaderAndCloseWhenSafe;
- (void)scheduleOutputDrainAfterTaskExit;

@end

@implementation PBTask

+ (instancetype)taskWithLaunchPath:(NSString *)launchPath arguments:(NSArray *)arguments inDirectory:(NSString *)directory
{
	return [[self alloc] initWithLaunchPath:launchPath arguments:arguments inDirectory:directory];
}

- (instancetype)initWithLaunchPath:(NSString *)launchPath arguments:(NSArray *)args inDirectory:(NSString *)directory
{
	self = [super init];
	if (!self) return nil;

	_task = [[NSTask alloc] init];
	_timeout = 30.0;
	[_task setLaunchPath:launchPath];
	[_task setArguments:args];

	// Prepare ourselves a nicer environment
	NSMutableDictionary *env = [[PBProcessEnvironment
		preparedEnvironment:[[NSProcessInfo processInfo] environment]
			  homeDirectory:NSHomeDirectory()] mutableCopy];
	[env removeObjectsForKeys:@[
		@"DYLD_INSERT_LIBRARIES", @"DYLD_LIBRARY_PATH",
		@"MallocGuardEdges", @"MallocNanoZone", @"MallocScribble", @"MallocStackLogging", @"MallocStackLoggingNoCompact",
		@"NSZombieEnabled"
	]];
	[_task setEnvironment:env];

	if (directory)
		[_task setCurrentDirectoryPath:directory];

	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"Show Debug Messages"])
		NSLog(@"Starting command `%@ %@` in dir %@", launchPath, [args componentsJoinedByString:@" "], directory);
#ifdef CLI
	NSLog(@"Starting command `%@ %@` in dir %@", launchPath, [args componentsJoinedByString:@" "], directory);
#endif

	_outputPipe = [NSPipe pipe];
	[_task setStandardOutput:_outputPipe];
	[_task setStandardError:_outputPipe];

	_standardOutputData = [NSData data];
	_standardOutputBuffer = [NSMutableData data];
	_stateQueue = dispatch_queue_create("org.gitx.PBTask.state", DISPATCH_QUEUE_SERIAL);

	PBTaskLog(@"task %p: init", self);

	return self;
}

- (void)dealloc
{
	PBTaskLog(@"task %p: dealloc", self);
}


- (NSArray<NSString *> *)taskArguments
{
	NSMutableArray<NSString *> *arguments = [NSMutableArray array];
	if (self.task.launchPath) [arguments addObject:self.task.launchPath];
	if (self.task.arguments) [arguments addObjectsFromArray:self.task.arguments];
	return arguments;
}

- (NSError *)timeoutError
{
	NSString *desc = @"Timeout while running task";
	NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" failed to complete before its timeout", [[self taskArguments] componentsJoinedByString:@" "]];
	NSDictionary *userInfo = @{
		NSLocalizedDescriptionKey : desc,
		NSLocalizedFailureReasonErrorKey : failureReason,
	};
	return [NSError errorWithDomain:PBTaskErrorDomain code:PBTaskTimeoutError userInfo:userInfo];
}

- (NSError *)terminationErrorForOutput:(NSData *)output
{
	if (self.terminationReason == NSTaskTerminationReasonUncaughtSignal) {
		PBTaskLog(@"task %p: caught signal", self);

		NSString *desc = @"Task killed";
		NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" caught a termination signal", [[self taskArguments] componentsJoinedByString:@" "]];
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey : desc,
			NSLocalizedFailureReasonErrorKey : failureReason,
		};
		return [NSError errorWithDomain:PBTaskErrorDomain code:PBTaskCaughtSignalError userInfo:userInfo];
	}

	if (self.terminationReason == NSTaskTerminationReasonExit && self.terminationStatus != 0) {
		PBTaskLog(@"task %p: exit != 0", self);

		NSString *outputString = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
		NSString *desc = @"Task exited unsuccessfully";
		NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" returned a non-zero return code", [[self taskArguments] componentsJoinedByString:@" "]];
		int status = self.terminationStatus;
		NSNumber *terminationStatus = (status < 255 ? [NSNumber numberWithShort:(short)status] : @(status));

		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey : desc,
			NSLocalizedFailureReasonErrorKey : failureReason,
			PBTaskTerminationStatusKey : terminationStatus,
			PBTaskTerminationOutputKey : outputString,
		};
		return [NSError errorWithDomain:PBTaskErrorDomain code:PBTaskNonZeroExitCodeError userInfo:userInfo];
	}

	PBTaskLog(@"task %p: exit success", self);
	return nil;
}

- (void)finishIfReady
{
	if (self.operationFinished) return;
	if (!self.forcedError && (!self.taskFinished || !self.outputFinished)) return;

	self.operationFinished = YES;
	NSData *output = [self.standardOutputBuffer copy] ?: [NSData data];
	self.standardOutputData = output;
	self.standardOutputBuffer = nil;
	NSError *error = self.forcedError ?: [self terminationErrorForOutput:output];
	dispatch_queue_t callbackQueue = self.callbackQueue;
	void (^resultHandler)(NSData *, NSError *) = self.resultHandler;

	[self stopOutputReaderAndCloseWhenSafe];
	self.inputPipe.fileHandleForWriting.writeabilityHandler = nil;
	@synchronized(self) {
		self.task.terminationHandler = nil;
	}
	self.resultHandler = nil;
	self.callbackQueue = nil;
	self.operationRetainer = nil;

	dispatch_async(callbackQueue, ^{
		resultHandler(error ? nil : output, error);
	});
}

- (void)stopOutputReaderAndCloseWhenSafe
{
	NSFileHandle *outputHandle = self.outputPipe.fileHandleForReading;
	BOOL closeNow;
	@synchronized(self) {
		self.outputReaderStopped = YES;
		self.outputHandleClosePending = YES;
		closeNow = self.outputReadsInFlight == 0 && !self.outputHandleClosed;
		if (closeNow) self.outputHandleClosed = YES;
	}
	outputHandle.readabilityHandler = nil;
	if (closeNow) [outputHandle closeFile];
}

- (void)scheduleOutputDrainAfterTaskExit
{
	if (self.outputFinished || self.outputDrainScheduled) return;
	self.outputDrainScheduled = YES;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PBTaskOutputDrainGrace * NSEC_PER_SEC)), self.stateQueue, ^{
		if (self.operationFinished || self.outputFinished) return;

		@synchronized(self) {
			self.outputDrainExpired = YES;
		}
		[self stopOutputReaderAndCloseWhenSafe];
		NSUInteger readsInFlight;
		@synchronized(self) {
			readsInFlight = self.outputReadsInFlight;
		}
		if (readsInFlight == 0) {
			self.outputFinished = YES;
			[self finishIfReady];
		}
	});
}

- (void)finishWithError:(NSError *)error
{
	dispatch_async(self.stateQueue, ^{
		if (self.operationFinished) return;
		self.forcedError = error;
		self.taskFinished = YES;
		self.outputFinished = YES;
		[self finishIfReady];
	});
}

- (void)configureOutputReader
{
	__weak PBTask *weakSelf = self;
	self.outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
		PBTask *strongSelf = weakSelf;
		if (!strongSelf) return;
		@synchronized(strongSelf) {
			if (strongSelf.outputReaderStopped) return;
			strongSelf.outputReadsInFlight += 1;
		}

		PBTaskLog(@"task %p: can read %d", strongSelf, handle.fileDescriptor);
		NSData *data = handle.availableData;
		dispatch_async(strongSelf.stateQueue, ^{
			BOOL shouldFinishAfterDrain;
			BOOL closeOutputHandle;
			@synchronized(strongSelf) {
				strongSelf.outputReadsInFlight -= 1;
				shouldFinishAfterDrain = strongSelf.outputDrainExpired && strongSelf.outputReadsInFlight == 0;
				closeOutputHandle = strongSelf.outputHandleClosePending && strongSelf.outputReadsInFlight == 0 && !strongSelf.outputHandleClosed;
				if (closeOutputHandle) strongSelf.outputHandleClosed = YES;
			}
			if (strongSelf.operationFinished) {
				if (closeOutputHandle) [handle closeFile];
				return;
			}
			if (data.length) {
				[strongSelf.standardOutputBuffer appendData:data];
			} else if (!data.length) {
				PBTaskLog(@"task %p: EOF, closing %d", strongSelf, handle.fileDescriptor);
				strongSelf.outputFinished = YES;
				[strongSelf finishIfReady];
			}
			if (shouldFinishAfterDrain && !strongSelf.outputFinished) {
				strongSelf.outputFinished = YES;
				[strongSelf finishIfReady];
			}
			if (closeOutputHandle) [handle closeFile];
		});
	};
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue resultHandler:(void (^)(NSData *_Nullable, NSError *_Nullable))resultHandler
{
	NSParameterAssert(queue != nil);
	NSParameterAssert(resultHandler != nil);

	dispatch_sync(self.stateQueue, ^{
		NSAssert(!self.operationStarted, @"PBTask instances can only be performed once");
		self.operationStarted = YES;
		self.callbackQueue = queue;
		self.resultHandler = resultHandler;
		self.operationRetainer = self;
	});
	[self configureOutputReader];

	// additionalEnvironment is intentionally mutable until launch time. A
	// number of callers configure a task after creating it, so folding these
	// values into NSTask's environment in the initializer is too early.
	if (self.additionalEnvironment.count) {
		NSMutableDictionary *environment = [self.task.environment mutableCopy] ?: [NSMutableDictionary dictionary];
		[environment addEntriesFromDictionary:self.additionalEnvironment];
		self.task.environment = environment;
	}

	__weak PBTask *weakSelf = self;
	@synchronized(self) {
		self.task.terminationHandler = ^(NSTask *task) {
			PBTask *strongSelf = weakSelf;
			if (!strongSelf) return;
			NSTaskTerminationReason reason;
			int status;
			@synchronized(strongSelf) {
				reason = task.terminationReason;
				status = task.terminationStatus;
			}
			dispatch_async(strongSelf.stateQueue, ^{
				if (strongSelf.operationFinished) return;
				strongSelf.terminationReason = reason;
				strongSelf.terminationStatus = status;
				strongSelf.taskFinished = YES;
				[strongSelf finishIfReady];
				[strongSelf scheduleOutputDrainAfterTaskExit];
			});
		};
	}

	if (self.standardInputData) {
		self.inputPipe = [NSPipe pipe];
		self.task.standardInput = self.inputPipe;

		self.inputPipe.fileHandleForWriting.writeabilityHandler = ^(NSFileHandle *handle) {
			PBTask *strongSelf = weakSelf;
			if (!strongSelf) return;
			PBTaskLog(@"task %p: can write %d", strongSelf, handle.fileDescriptor);

			[handle writeData:strongSelf.standardInputData];
			[handle closeFile];
		};
	}

	@try {
		PBTaskLog(@"task %p: launching", self);
		__block BOOL cancelled = NO;
		@synchronized(self) {
			cancelled = self.cancellationRequested;
			if (!cancelled) [self.task launch];
		}
		if (cancelled) {
			NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
												 code:NSUserCancelledError
											 userInfo:@{NSLocalizedDescriptionKey : @"Task cancelled before launch"}];
			[self finishWithError:error];
		} else if (self.timeout > 0) {
			NSTimeInterval timeout = self.timeout;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				PBTask *strongSelf = weakSelf;
				if (!strongSelf) return;
				dispatch_async(strongSelf.stateQueue, ^{
					if (strongSelf.operationFinished || strongSelf.taskFinished) return;
					BOOL taskWasRunning;
					@synchronized(strongSelf) {
						taskWasRunning = strongSelf.task.running;
						if (taskWasRunning) [strongSelf.task terminate];
					}
					if (!taskWasRunning) return;
					strongSelf.forcedError = [strongSelf timeoutError];
					strongSelf.taskFinished = YES;
					strongSelf.outputFinished = YES;
					[strongSelf finishIfReady];
				});
			});
		}
	}
	@catch (NSException *exception) {
		NSString *desc = @"Exception raised while launching task";
		NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" failed to launch", self.task.launchPath];
		NSDictionary *info = @{
			NSLocalizedDescriptionKey : desc,
			NSLocalizedFailureReasonErrorKey : failureReason,
			PBTaskUnderlyingExceptionKey : exception,
		};
		NSError *error = [NSError errorWithDomain:PBTaskErrorDomain
											 code:PBTaskLaunchError
										 userInfo:info];

		[self finishWithError:error];
	}
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue terminationHandler:(void (^)(NSError *_Nullable))terminationHandler
{
	NSParameterAssert(terminationHandler != nil);
	[self performTaskOnQueue:queue
			   resultHandler:^(NSData *data, NSError *error) {
				   terminationHandler(error);
			   }];
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue completionHandler:(void (^)(NSData *readData, NSError *error))completionHandler
{
	NSParameterAssert(completionHandler != nil);
	[self performTaskOnQueue:queue resultHandler:completionHandler];
}

- (BOOL)launchTask:(NSError **)error
{
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);

	__block NSError *taskError = nil;

	[self performTaskOnQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
		   completionHandler:^(NSData *readData, NSError *error) {
			   taskError = error;

			   dispatch_semaphore_signal(sem);
		   }];

	PBTaskLog(@"task %p: waiting for completion", self);
	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

	if (error) *error = taskError;
	return (taskError == nil);
}

- (void)terminate
{
	@synchronized(self) {
		self.cancellationRequested = YES;
		if (self.task.running) [self.task terminate];
	}
}

- (NSString *)description
{
	NSArray *taskArguments = [@[ self.task.launchPath ] arrayByAddingObjectsFromArray:self.task.arguments];
	return [NSString stringWithFormat:@"<%@ %p command: %@ stdin: %@>", NSStringFromClass([self class]), self,
									  [taskArguments componentsJoinedByString:@" "],
									  (self.standardInputData ? @"YES" : @"NO")];
}

@end

@implementation PBTask (PBBellsAndWhistles)

+ (NSString *)outputForCommand:(NSString *)launchPath arguments:(NSArray *)arguments error:(NSError **)error
{
	return [self outputForCommand:launchPath arguments:arguments inDirectory:nil error:error];
}

+ (NSString *)outputForCommand:(NSString *)launchPath arguments:(NSArray *)arguments inDirectory:(NSString *)directory error:(NSError **)error
{
	PBTask *task = [self taskWithLaunchPath:launchPath arguments:arguments inDirectory:directory];
	BOOL success = [task launchTask:error];
	if (!success) return nil;

	return task.standardOutputString;
}

+ (void)launchTask:(NSString *)launchPath arguments:(NSArray *)arguments inDirectory:(NSString *)directory completionHandler:(void (^)(NSData *readData, NSError *error))completionHandler
{
	PBTask *task = [self taskWithLaunchPath:launchPath arguments:arguments inDirectory:directory];
	[task performTaskWithCompletionHandler:completionHandler];
}

- (NSString *)standardOutputString
{
	return [[NSString alloc] initWithData:self.standardOutputData encoding:NSUTF8StringEncoding];
}

@end

@implementation PBTask (PBMainQueuePerform)

- (void)performTaskWithTerminationHandler:(void (^)(NSError *error))terminationHandler
{
	[self performTaskOnQueue:dispatch_get_main_queue() terminationHandler:terminationHandler];
}

- (void)performTaskWithCompletionHandler:(void (^)(NSData *__nullable readData, NSError *__nullable error))completionHandler
{
	[self performTaskOnQueue:dispatch_get_main_queue() completionHandler:completionHandler];
}

@end

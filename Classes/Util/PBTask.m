//
//  PBTask.m
//  GitX
//
//  Created by Etienne on 22/02/2017.
//
//

#import "PBTask.h"
#import "GitX-Swift.h"

#import <fcntl.h>
#import <math.h>
#import <signal.h>
#import <sys/wait.h>

NSString *const PBTaskErrorDomain = @"PBTaskErrorDomain";
NSString *const PBTaskUnderlyingExceptionKey = @"PBTaskUnderlyingExceptionKey";
NSString *const PBTaskTerminationStatusKey = @"PBTaskTerminationStatusKey";
NSString *const PBTaskTerminationOutputKey = @"PBTaskTerminationOutputKey";

const BOOL PBTaskDebugEnable = NO;
static const NSTimeInterval PBTaskOutputDrainGrace = 0.1;
static const NSTimeInterval PBTaskTerminationGrace = 0.2;
static const NSUInteger PBTaskStandardErrorLimit = 64 * 1024;

#define PBTaskLog(...)                             \
	do {                                           \
		if (PBTaskDebugEnable) NSLog(__VA_ARGS__); \
	} while (0)

@interface PBTask ()

@property (copy) NSString *launchPath;
@property (copy) NSArray<NSString *> *arguments;
@property (copy) NSDictionary<NSString *, NSString *> *environment;
@property (nullable, copy) NSString *currentDirectoryPath;
@property (nullable, strong) PBChildProcessSupervisor *processSupervisor;
@property (retain) NSData *standardOutputData;
@property (retain) NSMutableData *standardOutputBuffer;
@property (retain) NSData *standardErrorData;
@property (retain) NSMutableData *standardErrorBuffer;
@property BOOL didLogStandardErrorTruncation;
@property (nullable, retain) NSPipe *outputPipe;
@property (nullable, retain) NSPipe *errorPipe;
@property (nullable, retain) NSPipe *inputPipe;
@property (strong) dispatch_queue_t stateQueue;
@property (strong) dispatch_queue_t callbackQueue;
@property (copy) void (^resultHandler)(NSData *_Nullable data, NSError *_Nullable error);
@property (nullable, copy) PBTaskOutputChunkHandler outputChunkHandler;
@property (strong) PBTask *operationRetainer;
@property BOOL cancellationRequested;
@property BOOL operationStarted;
@property BOOL taskFinished;
@property BOOL outputFinished;
@property BOOL errorFinished;
@property BOOL operationFinished;
@property BOOL outputReaderStopped;
@property BOOL outputDrainScheduled;
@property BOOL outputDrainExpired;
@property BOOL diagnosticLeaderReleased;
@property BOOL diagnosticDrainScheduled;
@property NSTimeInterval diagnosticDrainDeadline;
@property NSUInteger diagnosticDrainGeneration;
@property NSUInteger outputReadsInFlight;
@property BOOL outputHandleClosePending;
@property BOOL outputHandleClosed;
@property BOOL errorReaderStopped;
@property NSUInteger errorReadsInFlight;
@property BOOL errorHandleClosePending;
@property BOOL errorHandleClosed;
@property NSTaskTerminationReason terminationReason;
@property int terminationStatus;
@property (retain) NSError *forcedError;

- (void)stopOutputReaderAndCloseWhenSafe;
- (void)stopErrorReaderAndCloseWhenSafe;
- (void)scheduleOutputDrainAfterTaskExit;
- (void)scheduleDiagnosticDrainAfterDelay:(NSTimeInterval)delay;
- (void)releaseDiagnosticLeaderWhenReadersFinish;
- (void)deliverReaderBlock:(dispatch_block_t)block;
- (nullable NSPipe *)makePipe;
- (NSArray<NSString *> *)validatedArgumentsForLaunch;
- (nullable NSError *)recordProcessCompletionWithRawWaitStatus:(int32_t)rawWaitStatus
											  supervisionError:(nullable NSError *)supervisionError;

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

	_timeout = 30.0;
	_launchPath = [launchPath copy];
	_arguments = [args copy] ?: @[];

	// Prepare ourselves a nicer environment
	NSMutableDictionary *env = [[PBProcessEnvironment
		preparedEnvironment:[[NSProcessInfo processInfo] environment]
			  homeDirectory:NSHomeDirectory()] mutableCopy];
	[env removeObjectsForKeys:@[
		@"DYLD_INSERT_LIBRARIES", @"DYLD_LIBRARY_PATH",
		@"MallocGuardEdges", @"MallocNanoZone", @"MallocScribble", @"MallocStackLogging", @"MallocStackLoggingNoCompact",
		@"NSZombieEnabled"
	]];
	_environment = [env copy];
	_currentDirectoryPath = [directory copy];

	_standardOutputData = [NSData data];
	_standardOutputBuffer = [NSMutableData data];
	_standardErrorData = [NSData data];
	_standardErrorBuffer = [NSMutableData data];
	_capturesStandardOutput = YES;
	_errorFinished = YES;
	dispatch_queue_attr_t stateQueueAttributes =
		dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
	_stateQueue = dispatch_queue_create("org.gitx.PBTask.state", stateQueueAttributes);

	PBTaskLog(@"task %p: init", self);

	return self;
}

- (void)dealloc
{
	PBTaskLog(@"task %p: dealloc", self);
}

- (nullable NSPipe *)makePipe
{
	return [NSPipe pipe];
}


- (NSArray<NSString *> *)taskArguments
{
	NSMutableArray<NSString *> *arguments = [NSMutableArray array];
	if (self.launchPath) [arguments addObject:self.launchPath];
	if (self.arguments) [arguments addObjectsFromArray:self.arguments];
	return arguments;
}

- (NSError *)timeoutError
{
	NSString *desc = @"Timeout while running task";
	NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" failed to complete before its timeout", [PBTaskDiagnostics displayArguments:[self taskArguments]]];
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
		NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" caught a termination signal", [PBTaskDiagnostics displayArguments:[self taskArguments]]];
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey : desc,
			NSLocalizedFailureReasonErrorKey : failureReason,
		};
		return [NSError errorWithDomain:PBTaskErrorDomain code:PBTaskCaughtSignalError userInfo:userInfo];
	}

	if (self.terminationReason == NSTaskTerminationReasonExit && self.terminationStatus != 0) {
		PBTaskLog(@"task %p: exit != 0", self);

		NSData *diagnosticOutput = self.separatesStandardError && self.standardErrorData.length ? self.standardErrorData : output;
		NSString *outputString = self.diagnosticCapture ? self.diagnosticCapture.artifact.redactedSummary : ([[NSString alloc] initWithData:diagnosticOutput encoding:NSUTF8StringEncoding] ?: @"");
		NSString *desc = @"Task exited unsuccessfully";
		NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" returned a non-zero return code", [PBTaskDiagnostics displayArguments:[self taskArguments]]];
		int status = self.terminationStatus;
		NSNumber *terminationStatus = (status < 255 ? [NSNumber numberWithShort:(short)status] : @(status));

		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey : desc,
			NSLocalizedFailureReasonErrorKey : failureReason,
			PBTaskTerminationStatusKey : terminationStatus,
			PBTaskTerminationOutputKey : [PBTaskDiagnostics redacted:outputString],
		};
		return [NSError errorWithDomain:PBTaskErrorDomain code:PBTaskNonZeroExitCodeError userInfo:userInfo];
	}

	PBTaskLog(@"task %p: exit success", self);
	return nil;
}

- (void)finishIfReady
{
	if (self.operationFinished) return;
	[self releaseDiagnosticLeaderWhenReadersFinish];
	if (!self.taskFinished) return;
	if ((!self.forcedError || self.diagnosticCapture) && (!self.outputFinished || !self.errorFinished)) return;
	if (self.diagnosticCapture) {
		@synchronized(self) {
			if (self.outputReadsInFlight || self.errorReadsInFlight) return;
		}
		[self.diagnosticCapture seal];
	}

	self.operationFinished = YES;
	NSData *output = [self.standardOutputBuffer copy] ?: [NSData data];
	self.standardOutputData = output;
	self.standardOutputBuffer = nil;
	self.standardErrorData = [self.standardErrorBuffer copy] ?: [NSData data];
	self.standardErrorBuffer = nil;
	NSError *error = self.forcedError ?: [self terminationErrorForOutput:output];
	dispatch_queue_t callbackQueue = self.callbackQueue;
	void (^resultHandler)(NSData *, NSError *) = self.resultHandler;

	[self stopOutputReaderAndCloseWhenSafe];
	[self stopErrorReaderAndCloseWhenSafe];
	self.inputPipe.fileHandleForWriting.writeabilityHandler = nil;
	self.processSupervisor = nil;
	self.resultHandler = nil;
	self.outputChunkHandler = nil;
	self.callbackQueue = nil;
	self.operationRetainer = nil;

	dispatch_async(callbackQueue, ^{
		resultHandler(error ? nil : output, error);
	});
}

- (void)deliverReaderBlock:(dispatch_block_t)block
{
	// Captured pushes back-pressure each reader instead of accumulating an unbounded
	// queue of chunks behind file writes. Existing callers keep their delivery contract.
	if (self.diagnosticCapture)
		dispatch_sync(self.stateQueue, block);
	else
		dispatch_async(self.stateQueue, block);
}

- (void)releaseDiagnosticLeaderWhenReadersFinish
{
	if (!self.diagnosticCapture || self.diagnosticLeaderReleased || !self.outputFinished || !self.errorFinished) return;
	[self stopOutputReaderAndCloseWhenSafe];
	[self stopErrorReaderAndCloseWhenSafe];
	@synchronized(self) {
		if (self.outputReadsInFlight || self.errorReadsInFlight) return;
	}
	self.diagnosticLeaderReleased = YES;
	[self.processSupervisor releaseLeaderRetention];
}

- (void)scheduleDiagnosticDrainAfterDelay:(NSTimeInterval)delay
{
	if (!self.diagnosticCapture || self.operationFinished || !isfinite(delay) || delay > (double)INT64_MAX / NSEC_PER_SEC) return;
	delay = MAX(0.0, delay);
	NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + delay;
	if (self.diagnosticDrainScheduled && self.diagnosticDrainDeadline <= deadline) return;
	self.diagnosticDrainScheduled = YES;
	self.diagnosticDrainDeadline = deadline;
	NSUInteger generation = ++self.diagnosticDrainGeneration;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.stateQueue, ^{
		if (self.operationFinished || generation != self.diagnosticDrainGeneration) return;
		@synchronized(self) {
			self.outputDrainExpired = YES;
		}
		[self stopOutputReaderAndCloseWhenSafe];
		[self stopErrorReaderAndCloseWhenSafe];
		@synchronized(self) {
			if (!self.outputReadsInFlight) self.outputFinished = YES;
			if (!self.errorReadsInFlight) self.errorFinished = YES;
		}
		[self finishIfReady];
	});
}

- (void)stopErrorReaderAndCloseWhenSafe
{
	NSFileHandle *errorHandle = self.errorPipe.fileHandleForReading;
	if (!errorHandle) return;
	BOOL closeNow;
	@synchronized(self) {
		self.errorReaderStopped = YES;
		self.errorHandleClosePending = YES;
		closeNow = self.errorReadsInFlight == 0 && !self.errorHandleClosed;
		if (closeNow) self.errorHandleClosed = YES;
	}
	errorHandle.readabilityHandler = nil;
	if (closeNow) [errorHandle closeFile];
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
	if (self.diagnosticCapture) {
		// Normal captured pushes release ownership only after real EOF. A supervisor
		// error can complete ownership early; that path still gets bounded pipe cleanup.
		[self scheduleDiagnosticDrainAfterDelay:PBTaskOutputDrainGrace];
		return;
	}
	if ((self.outputFinished && self.errorFinished) || self.outputDrainScheduled) return;
	self.outputDrainScheduled = YES;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PBTaskOutputDrainGrace * NSEC_PER_SEC)), self.stateQueue, ^{
		if (self.operationFinished || (self.outputFinished && self.errorFinished)) return;

		@synchronized(self) {
			self.outputDrainExpired = YES;
		}
		[self stopOutputReaderAndCloseWhenSafe];
		[self stopErrorReaderAndCloseWhenSafe];
		NSUInteger readsInFlight;
		NSUInteger errorReadsInFlight;
		@synchronized(self) {
			readsInFlight = self.outputReadsInFlight;
			errorReadsInFlight = self.errorReadsInFlight;
		}
		if (readsInFlight == 0) self.outputFinished = YES;
		if (errorReadsInFlight == 0) self.errorFinished = YES;
		[self finishIfReady];
	});
}

- (void)finishWithError:(NSError *)error
{
	dispatch_async(self.stateQueue, ^{
		if (self.operationFinished) return;
		self.forcedError = error;
		self.taskFinished = YES;
		self.outputFinished = YES;
		self.errorFinished = YES;
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
		[strongSelf deliverReaderBlock:^{
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
				[strongSelf.diagnosticCapture appendStandardOutput:data];
				if (strongSelf.capturesStandardOutput) {
					if (strongSelf.diagnosticCapture) {
						NSUInteger remaining = PBTaskStandardErrorLimit - strongSelf.standardOutputBuffer.length;
						if (remaining) [strongSelf.standardOutputBuffer appendData:[data subdataWithRange:NSMakeRange(0, MIN(remaining, data.length))]];
					} else {
						[strongSelf.standardOutputBuffer appendData:data];
					}
				}
				PBTaskOutputChunkHandler outputChunkHandler = strongSelf.outputChunkHandler;
				if (outputChunkHandler) outputChunkHandler(data);
			} else if (!data.length) {
				PBTaskLog(@"task %p: EOF, closing %d", strongSelf, handle.fileDescriptor);
				strongSelf.outputFinished = YES;
				[strongSelf.diagnosticCapture finishStandardOutputWithReachedEOF:YES];
				if (strongSelf.diagnosticCapture) [strongSelf stopOutputReaderAndCloseWhenSafe];
				[strongSelf finishIfReady];
			}
			if (shouldFinishAfterDrain && !strongSelf.outputFinished) {
				strongSelf.outputFinished = YES;
				[strongSelf finishIfReady];
			}
			if (closeOutputHandle) [handle closeFile];
			// Forced errors can stop readers while a nonempty chunk is already
			// accepted. Reevaluate only after preserving it and closing its handle.
			if (strongSelf.diagnosticCapture && data.length) [strongSelf finishIfReady];
		}];
	};
}

- (void)configureErrorReader
{
	__weak PBTask *weakSelf = self;
	self.errorPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
		PBTask *strongSelf = weakSelf;
		if (!strongSelf) return;
		@synchronized(strongSelf) {
			if (strongSelf.errorReaderStopped) return;
			strongSelf.errorReadsInFlight += 1;
		}
		PBTaskLog(@"task %p: can read standard error %d", strongSelf, handle.fileDescriptor);
		NSData *data = handle.availableData;
		[strongSelf deliverReaderBlock:^{
			BOOL shouldFinishAfterDrain;
			BOOL closeErrorHandle;
			@synchronized(strongSelf) {
				strongSelf.errorReadsInFlight -= 1;
				shouldFinishAfterDrain = strongSelf.outputDrainExpired && strongSelf.errorReadsInFlight == 0;
				closeErrorHandle = strongSelf.errorHandleClosePending && strongSelf.errorReadsInFlight == 0 && !strongSelf.errorHandleClosed;
				if (closeErrorHandle) strongSelf.errorHandleClosed = YES;
			}
			if (strongSelf.operationFinished) {
				if (closeErrorHandle) [handle closeFile];
				return;
			}
			if (data.length) {
				[strongSelf.diagnosticCapture appendStandardError:data];
				[strongSelf.standardErrorBuffer appendData:data];
				if (strongSelf.standardErrorBuffer.length > PBTaskStandardErrorLimit) {
					NSUInteger cut = strongSelf.standardErrorBuffer.length - PBTaskStandardErrorLimit;
					const uint8_t *bytes = strongSelf.standardErrorBuffer.bytes;
					while (cut < strongSelf.standardErrorBuffer.length && (bytes[cut] & 0xC0) == 0x80)
						cut += 1;
					if (!strongSelf.didLogStandardErrorTruncation) {
						strongSelf.didLogStandardErrorTruncation = YES;
						NSLog(@"[GitX] PBTask %p began truncating standard error at the 64 KiB cap; first discarded segment: %lu bytes at a UTF-8 boundary", strongSelf, (unsigned long)cut);
					}
					[strongSelf.standardErrorBuffer replaceBytesInRange:NSMakeRange(0, cut) withBytes:NULL length:0];
				}
			} else {
				strongSelf.errorFinished = YES;
				[strongSelf.diagnosticCapture finishStandardErrorWithReachedEOF:YES];
				if (strongSelf.diagnosticCapture) [strongSelf stopErrorReaderAndCloseWhenSafe];
				[strongSelf finishIfReady];
			}
			if (shouldFinishAfterDrain && !strongSelf.errorFinished) {
				strongSelf.errorFinished = YES;
				[strongSelf finishIfReady];
			}
			if (closeErrorHandle) [handle closeFile];
			if (strongSelf.diagnosticCapture && data.length) [strongSelf finishIfReady];
		}];
	};
}

- (NSDictionary<NSString *, NSString *> *)environmentForLaunch
{
	NSMutableDictionary<NSString *, NSString *> *environment = [self.environment mutableCopy];
	[self.additionalEnvironment enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
		if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) {
			[NSException raise:NSInvalidArgumentException format:@"PBTask environment keys and values must be strings"];
		}
		environment[key] = value;
	}];
	return environment;
}

- (NSArray<NSString *> *)validatedArgumentsForLaunch
{
	NSMutableArray<NSString *> *validatedArguments = [NSMutableArray arrayWithCapacity:self.arguments.count];
	for (id argument in (NSArray *)self.arguments) {
		if (![argument isKindOfClass:[NSString class]])
			[NSException raise:NSInvalidArgumentException format:@"PBTask arguments must be strings"];
		[validatedArguments addObject:argument];
	}
	return validatedArguments;
}

- (NSError *)launchErrorForException:(NSException *)exception underlyingError:(NSError *)underlyingError
{
	NSString *desc = @"Exception raised while launching task";
	NSString *failureReason = [NSString stringWithFormat:@"The task \"%@\" failed to launch", [PBTaskDiagnostics redacted:self.launchPath]];
	NSMutableDictionary *info = [@{
		NSLocalizedDescriptionKey : desc,
		NSLocalizedFailureReasonErrorKey : failureReason,
		PBTaskUnderlyingExceptionKey : exception,
	} mutableCopy];
	if (underlyingError) info[NSUnderlyingErrorKey] = underlyingError;
	return [NSError errorWithDomain:PBTaskErrorDomain code:PBTaskLaunchError userInfo:info];
}

- (nullable NSError *)recordProcessCompletionWithRawWaitStatus:(int32_t)rawWaitStatus
											  supervisionError:(nullable NSError *)supervisionError
{
	if (supervisionError) {
		NSException *exception = [NSException exceptionWithName:@"PBTaskProcessSupervisionException"
														 reason:supervisionError.localizedDescription
													   userInfo:@{NSUnderlyingErrorKey : supervisionError}];
		self.forcedError = [self launchErrorForException:exception underlyingError:supervisionError];
	} else if (WIFSIGNALED(rawWaitStatus)) {
		self.terminationReason = NSTaskTerminationReasonUncaughtSignal;
		self.terminationStatus = WTERMSIG(rawWaitStatus);
	} else {
		self.terminationReason = NSTaskTerminationReasonExit;
		self.terminationStatus = WIFEXITED(rawWaitStatus) ? WEXITSTATUS(rawWaitStatus) : rawWaitStatus;
	}
	return self.forcedError;
}

- (void)closeChildPipeEnds
{
	[self.outputPipe.fileHandleForWriting closeFile];
	[self.errorPipe.fileHandleForWriting closeFile];
	[self.inputPipe.fileHandleForReading closeFile];
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue
		outputChunkHandler:(PBTaskOutputChunkHandler)outputChunkHandler
			 resultHandler:(void (^)(NSData *_Nullable, NSError *_Nullable))resultHandler
{
	NSParameterAssert(queue != nil);
	NSParameterAssert(resultHandler != nil);

	dispatch_sync(self.stateQueue, ^{
		NSAssert(!self.operationStarted, @"PBTask instances can only be performed once");
		self.operationStarted = YES;
		self.callbackQueue = queue;
		self.resultHandler = resultHandler;
		self.outputChunkHandler = outputChunkHandler;
		self.operationRetainer = self;
		if (self.diagnosticCapture) self.separatesStandardError = YES;
		self.errorFinished = !self.separatesStandardError;
		if (self.errorFinished) [self.diagnosticCapture finishStandardErrorWithReachedEOF:YES];
	});

	__weak PBTask *weakSelf = self;

	@try {
		NSArray<NSString *> *validatedArguments = [self validatedArgumentsForLaunch];
		self.outputPipe = [self makePipe];
		if (!self.outputPipe)
			[NSException raise:@"PBTaskPipeCreationException" format:@"Could not create standard output pipe"];
		[self configureOutputReader];
		if (self.separatesStandardError) {
			self.errorPipe = [self makePipe];
			if (!self.errorPipe)
				[NSException raise:@"PBTaskPipeCreationException" format:@"Could not create standard error pipe"];
			[self configureErrorReader];
		}

		if (self.standardInputData) {
			self.inputPipe = [self makePipe];
			if (!self.inputPipe)
				[NSException raise:@"PBTaskPipeCreationException" format:@"Could not create standard input pipe"];
			NSFileHandle *inputHandle = self.inputPipe.fileHandleForWriting;
			(void)fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1);

			inputHandle.writeabilityHandler = ^(NSFileHandle *handle) {
				PBTask *strongSelf = weakSelf;
				if (!strongSelf) return;
				PBTaskLog(@"task %p: can write %d", strongSelf, handle.fileDescriptor);

				@try {
					[handle writeData:strongSelf.standardInputData];
				} @catch (NSException *exception) {
					// A child that exits without draining stdin (e.g. a fast-failing `git update-index --stdin`
					// on a locked index, or a hook that closes stdin) makes writeData: raise
					// NSFileHandleOperationException on EPIPE. It fires on a GCD thread where nothing catches it,
					// so swallow it here and still close the descriptor below to avoid leaking it.
					PBTaskLog(@"task %p: stdin write failed: %@", strongSelf, exception);
				} @finally {
					handle.writeabilityHandler = nil;
					[handle closeFile];
				}
			};
		}

		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"Show Debug Messages"])
			NSLog(@"Starting command `%@ %@` in dir %@", [PBTaskDiagnostics redacted:self.launchPath], [PBTaskDiagnostics displayArguments:validatedArguments], [PBTaskDiagnostics redacted:self.currentDirectoryPath]);
#ifdef CLI
		NSLog(@"Starting command `%@ %@` in dir %@", [PBTaskDiagnostics redacted:self.launchPath], [PBTaskDiagnostics displayArguments:validatedArguments], [PBTaskDiagnostics redacted:self.currentDirectoryPath]);
#endif

		PBTaskLog(@"task %p: launching", self);
		__block BOOL cancelled = NO;
		__block NSError *launchError = nil;
		@synchronized(self) {
			cancelled = self.cancellationRequested;
			if (!cancelled) {
				NSNumber *inputFileDescriptor = self.inputPipe ? @(self.inputPipe.fileHandleForReading.fileDescriptor) : nil;
				self.processSupervisor = [[PBChildProcessSupervisor alloc]
							  initWithLaunchPath:self.launchPath
									   arguments:validatedArguments
									 environment:[self environmentForLaunch]
								workingDirectory:self.currentDirectoryPath
					 standardInputFileDescriptor:inputFileDescriptor
					standardOutputFileDescriptor:self.outputPipe.fileHandleForWriting.fileDescriptor
					 standardErrorFileDescriptor:self.errorPipe ? @(self.errorPipe.fileHandleForWriting.fileDescriptor) : nil
							  terminationHandler:^(int32_t rawWaitStatus, NSError *supervisionError) {
								  PBTask *strongSelf = weakSelf;
								  if (!strongSelf) return;
								  dispatch_async(strongSelf.stateQueue, ^{
									  if (strongSelf.operationFinished) return;
									  [strongSelf recordProcessCompletionWithRawWaitStatus:rawWaitStatus supervisionError:supervisionError];
									  strongSelf.taskFinished = YES;
									  [strongSelf finishIfReady];
									  [strongSelf scheduleOutputDrainAfterTaskExit];
								  });
							  }];
				self.processSupervisor.retainLeaderUntilReleased = self.diagnosticCapture != nil;
				if (![self.processSupervisor launchAndReturnError:&launchError])
					self.processSupervisor = nil;
			}
		}
		[self closeChildPipeEnds];
		if (cancelled) {
			NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
												 code:NSUserCancelledError
											 userInfo:@{NSLocalizedDescriptionKey : @"Task cancelled before launch"}];
			[self finishWithError:error];
		} else if (launchError) {
			NSException *exception = [NSException exceptionWithName:@"PBTaskLaunchException"
															 reason:launchError.localizedDescription
														   userInfo:@{NSUnderlyingErrorKey : launchError}];
			[self finishWithError:[self launchErrorForException:exception underlyingError:launchError]];
		} else if (self.timeout > 0) {
			NSTimeInterval timeout = self.timeout;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), self.stateQueue, ^{
				PBTask *strongSelf = weakSelf;
				if (!strongSelf) return;
				if (strongSelf.operationFinished || strongSelf.taskFinished) return;
				if ([strongSelf.processSupervisor requestTimeoutTerminationWithForceKillAfter:PBTaskTerminationGrace]) {
					strongSelf.forcedError = [strongSelf timeoutError];
					[strongSelf scheduleDiagnosticDrainAfterDelay:PBTaskTerminationGrace + PBTaskOutputDrainGrace];
				}
			});
		}
	}
	@catch (NSException *exception) {
		[self closeChildPipeEnds];
		[self finishWithError:[self launchErrorForException:exception underlyingError:nil]];
	}
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue terminationHandler:(void (^)(NSError *_Nullable))terminationHandler
{
	NSParameterAssert(terminationHandler != nil);
	[self performTaskOnQueue:queue
		  outputChunkHandler:nil
			   resultHandler:^(NSData *data, NSError *error) {
				   terminationHandler(error);
			   }];
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue completionHandler:(void (^)(NSData *readData, NSError *error))completionHandler
{
	NSParameterAssert(completionHandler != nil);
	[self performTaskOnQueue:queue outputChunkHandler:nil resultHandler:completionHandler];
}

- (void)performTaskOnQueue:(dispatch_queue_t)queue
		outputChunkHandler:(PBTaskOutputChunkHandler)outputChunkHandler
		 completionHandler:(void (^)(NSData *, NSError *))completionHandler
{
	NSParameterAssert(completionHandler != nil);
	[self performTaskOnQueue:queue outputChunkHandler:outputChunkHandler resultHandler:completionHandler];
}

- (BOOL)launchTask:(NSError **)error
{
	return [self launchTaskWithOutputChunkHandler:nil error:error];
}

- (BOOL)launchTaskWithOutputChunkHandler:(PBTaskOutputChunkHandler)outputChunkHandler error:(NSError **)error
{
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);

	__block NSError *taskError = nil;

	[self performTaskOnQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
		  outputChunkHandler:outputChunkHandler
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
	PBChildProcessSupervisor *supervisor;
	@synchronized(self) {
		self.cancellationRequested = YES;
		supervisor = self.processSupervisor;
	}
	if (self.diagnosticCapture) {
		[supervisor requestTerminationAfterGracePeriod:0 forceKillAfter:@(PBTaskTerminationGrace)];
		dispatch_async(self.stateQueue, ^{
			[self scheduleDiagnosticDrainAfterDelay:PBTaskTerminationGrace + PBTaskOutputDrainGrace];
		});
	} else {
		[supervisor requestImmediateTermination];
	}
}

- (void)terminateAfterGracePeriod:(NSTimeInterval)gracePeriod forceKillAfter:(NSTimeInterval)forceKillDelay
{
	PBChildProcessSupervisor *supervisor;
	@synchronized(self) {
		self.cancellationRequested = YES;
		supervisor = self.processSupervisor;
	}
	[supervisor requestTerminationAfterGracePeriod:MAX(0, gracePeriod)
									forceKillAfter:@(MAX(0, forceKillDelay))];
	if (self.diagnosticCapture) {
		dispatch_async(self.stateQueue, ^{
			[self scheduleDiagnosticDrainAfterDelay:MAX(0.0, gracePeriod) + MAX(0.0, forceKillDelay) + PBTaskOutputDrainGrace];
		});
	}
}

- (NSString *)description
{
	NSArray *taskArguments = [@[ self.launchPath ] arrayByAddingObjectsFromArray:self.arguments];
	return [NSString stringWithFormat:@"<%@ %p command: %@ stdin: %@>", NSStringFromClass([self class]), self,
									  [PBTaskDiagnostics displayArguments:taskArguments],
									  (self.standardInputData ? @"YES" : @"NO")];
}

@end

@implementation PBTask (PBBellsAndWhistles)

+ (NSString *)outputForCommand:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments error:(NSError **)error
{
	return [self outputForCommand:launchPath arguments:arguments inDirectory:nil error:error];
}

+ (NSString *)outputForCommand:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory error:(NSError **)error
{
	PBTask *task = [self taskWithLaunchPath:launchPath arguments:arguments inDirectory:directory];
	BOOL success = [task launchTask:error];
	if (!success) return nil;

	return task.standardOutputString;
}

+ (void)launchTask:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory completionHandler:(void (^)(NSData *readData, NSError *error))completionHandler
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

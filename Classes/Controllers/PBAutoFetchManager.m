#import "PBAutoFetchManager.h"

#import "PBGitBinary.h"
#import "PBGitDefaults.h"
#import "PBGitHistoryController.h"
#import "PBGitRef.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitRevSpecifier.h"
#import "PBGitWindowController.h"
#import "PBRepositoryDocumentController.h"
#import "PBTask.h"

#import <ObjectiveGit/GTOID.h>
#import <UserNotifications/UserNotifications.h>

static NSTimeInterval const PBAutoFetchTimerResolution = 30.0;
static NSTimeInterval const PBAutoFetchRetryBaseInterval = 60.0;
static NSTimeInterval const PBAutoFetchRetryMaximumInterval = 15.0 * 60.0;

@interface PBAutoFetchManager () <UNUserNotificationCenterDelegate>
@property (nonatomic) NSTimer *timer;
@property (nonatomic) dispatch_queue_t fetchQueue;
@property (nonatomic) NSMutableDictionary<NSString *, NSDate *> *nextFetchDates;
@property (nonatomic) NSMutableSet<NSString *> *inFlightRepositories;
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *failureCounts;
@property (nonatomic) PBAutoFetchScope lastScope;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL requestedNotificationAuthorization;
@end

@implementation PBAutoFetchManager

+ (instancetype)sharedManager
{
	static PBAutoFetchManager *manager;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		manager = [[self alloc] init];
	});
	return manager;
}

- (instancetype)init
{
	self = [super init];
	if (!self) return nil;
	_fetchQueue = dispatch_queue_create("com.gitx.autofetch", DISPATCH_QUEUE_SERIAL);
	_nextFetchDates = [NSMutableDictionary dictionary];
	_inFlightRepositories = [NSMutableSet set];
	_failureCounts = [NSMutableDictionary dictionary];
	_lastScope = PBAutoFetchScopeNone;
	return self;
}

- (void)start
{
	if (self.started) return;
	self.started = YES;
	self.lastScope = [PBGitDefaults autoFetchScope];

	[UNUserNotificationCenter currentNotificationCenter].delegate = self;

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(autoFetchPreferencesChanged:) name:PBAutoFetchPreferencesDidChangeNotification object:nil];
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(workspaceDidWake:) name:NSWorkspaceDidWakeNotification object:nil];

	self.timer = [NSTimer scheduledTimerWithTimeInterval:PBAutoFetchTimerResolution
										 target:self
									 selector:@selector(timerFired:)
									 userInfo:nil
									  repeats:YES];
	if (self.lastScope != PBAutoFetchScopeNone) {
		[self ensureNotificationAuthorization];
		[self evaluateRepositoriesForImmediateFetch:YES];
	}
}

- (void)ensureNotificationAuthorization
{
	if (self.requestedNotificationAuthorization) return;
	self.requestedNotificationAuthorization = YES;
	[[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
												 completionHandler:^(__unused BOOL granted, __unused NSError *error) {}];
}

- (void)autoFetchPreferencesChanged:(NSNotification *)notification
{
	PBAutoFetchScope scope = [PBGitDefaults autoFetchScope];
	BOOL wasDisabled = self.lastScope == PBAutoFetchScopeNone;
	self.lastScope = scope;
	if (scope == PBAutoFetchScopeNone) return;
	[self ensureNotificationAuthorization];
	if (wasDisabled) {
		[self.nextFetchDates removeAllObjects];
		[self.failureCounts removeAllObjects];
	}
	[self evaluateRepositoriesForImmediateFetch:wasDisabled];
}

- (void)timerFired:(NSTimer *)timer
{
	[self evaluateRepositoriesForImmediateFetch:NO];
}

- (void)workspaceDidWake:(NSNotification *)notification
{
	// A wake represents one catch-up opportunity. The normal interval starts
	// again when that fetch is scheduled.
	[self.failureCounts removeAllObjects];
	[self evaluateRepositoriesForImmediateFetch:YES];
}

+ (NSTimeInterval)retryDelayForFailureCount:(NSUInteger)failureCount
{
	if (failureCount == 0) return 0;
	NSUInteger exponent = MIN(failureCount - 1, (NSUInteger)4);
	return MIN(PBAutoFetchRetryBaseInterval * (NSTimeInterval)(1UL << exponent), PBAutoFetchRetryMaximumInterval);
}

- (NSString *)keyForURL:(NSURL *)url
{
	return url.URLByStandardizingPath.path ?: url.path ?:
														 @"";
}

- (NSDictionary<NSString *, NSURL *> *)candidateRepositoryURLs
{
	PBAutoFetchScope scope = [PBGitDefaults autoFetchScope];
	if (scope == PBAutoFetchScopeNone) return @{};

	NSArray<NSDocument *> *documents = [NSDocumentController sharedDocumentController].documents;
	NSMutableDictionary<NSString *, NSURL *> *openURLs = [NSMutableDictionary dictionary];
	for (NSDocument *candidate in documents) {
		if (![candidate isKindOfClass:PBGitRepositoryDocument.class]) continue;
		PBGitRepository *repository = [(PBGitRepositoryDocument *)candidate repository];
		NSURL *url = repository.workingDirectoryURL;
		if (url) openURLs[[self keyForURL:url]] = url;
	}

	if (scope == PBAutoFetchScopeActiveRepository) {
		NSDocument *activeDocument = NSApp.keyWindow.windowController.document ?: [NSDocumentController sharedDocumentController].currentDocument;
		if (![activeDocument isKindOfClass:PBGitRepositoryDocument.class]) return @{};
		NSURL *url = [(PBGitRepositoryDocument *)activeDocument repository].workingDirectoryURL;
		return url ? @{ [self keyForURL:url] : url } : @{};
	}

	if (scope == PBAutoFetchScopeOpenAndRecentRepositories) {
		for (NSURL *url in [NSDocumentController sharedDocumentController].recentDocumentURLs) {
			if (url.isFileURL && url.path.length) openURLs[[self keyForURL:url]] = url;
		}
	}
	return openURLs;
}

- (void)evaluateRepositoriesForImmediateFetch:(BOOL)immediate
{
	if ([PBGitDefaults autoFetchScope] == PBAutoFetchScopeNone) return;
	NSDate *now = [NSDate date];
	NSDictionary<NSString *, NSURL *> *candidates = [self candidateRepositoryURLs];
	for (NSString *key in candidates) {
		if ([self.inFlightRepositories containsObject:key]) continue;
		NSDate *next = self.nextFetchDates[key];
		if (!immediate && next && [next compare:now] == NSOrderedDescending) continue;
		NSURL *url = candidates[key];
		[self.inFlightRepositories addObject:key];
		dispatch_async(self.fetchQueue, ^{
			[self fetchRepositoryAtURL:url key:key];
		});
	}
}

- (PBTask *)taskForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments
{
	PBTask *task = [PBTask taskWithLaunchPath:[PBGitBinary path] arguments:arguments inDirectory:url.path];
	task.timeout = 10.0 * 60.0;
	task.additionalEnvironment = @{
		@"GIT_TERMINAL_PROMPT" : @"0",
		@"GCM_INTERACTIVE" : @"never",
		@"GIT_ASKPASS" : @"/usr/bin/false",
	};
	return task;
}

- (nullable NSString *)outputForRepositoryURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments error:(NSError **)error
{
	PBTask *task = [self taskForRepositoryURL:url arguments:arguments];
	if (![task launchTask:error]) return nil;
	return task.standardOutputString ?: @"";
}

- (nullable NSDictionary<NSString *, NSString *> *)remoteSnapshotForURL:(NSURL *)url error:(NSError **)error
{
	NSString *output = [self outputForRepositoryURL:url
									  arguments:@[ @"for-each-ref", @"--format=%(refname)\t%(objectname)", @"refs/remotes" ]
										 error:error];
	if (!output) return nil;
	NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
	[output enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
		NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
		if (parts.count != 2 || [parts[0] hasSuffix:@"/HEAD"]) return;
		snapshot[parts[0]] = parts[1];
	}];
	return snapshot;
}

- (BOOL)isAncestor:(NSString *)oldSHA of:(NSString *)newSHA repositoryURL:(NSURL *)url
{
	NSError *error = nil;
	PBTask *task = [self taskForRepositoryURL:url arguments:@[ @"merge-base", @"--is-ancestor", oldSHA, newSHA ]];
	return [task launchTask:&error];
}

- (NSInteger)commitCountFrom:(NSString *)oldSHA to:(NSString *)newSHA repositoryURL:(NSURL *)url
{
	NSError *error = nil;
	NSString *range = [NSString stringWithFormat:@"%@..%@", oldSHA, newSHA];
	NSString *output = [self outputForRepositoryURL:url arguments:@[ @"rev-list", @"--count", range ] error:&error];
	return MAX(0, output.integerValue);
}

- (NSTimeInterval)commitTimestampForSHA:(NSString *)sha repositoryURL:(NSURL *)url
{
	NSError *error = nil;
	NSString *output = [self outputForRepositoryURL:url arguments:@[ @"show", @"-s", @"--format=%ct", sha ] error:&error];
	return error ? 0 : output.doubleValue;
}

- (void)fetchRepositoryAtURL:(NSURL *)url key:(NSString *)key
{
	NSError *error = nil;
	NSDictionary *before = [self remoteSnapshotForURL:url error:&error];
	if (before) {
		PBTask *fetch = [self taskForRepositoryURL:url arguments:@[ @"fetch", @"--all" ]];
		if (![fetch launchTask:&error]) before = nil;
	}
	NSDictionary *after = before ? [self remoteSnapshotForURL:url error:&error] : nil;

	NSMutableArray<NSDictionary *> *advances = [NSMutableArray array];
	if (before && after) {
		[after enumerateKeysAndObjectsUsingBlock:^(NSString *ref, NSString *newSHA, BOOL *stop) {
			NSString *oldSHA = before[ref];
			if (!oldSHA || [oldSHA isEqualToString:newSHA]) return;
			if (![self isAncestor:oldSHA of:newSHA repositoryURL:url]) return;
			NSInteger count = [self commitCountFrom:oldSHA to:newSHA repositoryURL:url];
			if (count > 0) {
				NSTimeInterval timestamp = [self commitTimestampForSHA:newSHA repositoryURL:url];
				[advances addObject:@{ @"ref" : ref, @"sha" : newSHA, @"count" : @(count), @"timestamp" : @(timestamp) }];
			}
		}];
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		[self.inFlightRepositories removeObject:key];
		if (!before || !after) {
			NSUInteger failureCount = self.failureCounts[key].unsignedIntegerValue + 1;
			self.failureCounts[key] = @(failureCount);
			self.nextFetchDates[key] = [[NSDate date] dateByAddingTimeInterval:[PBAutoFetchManager retryDelayForFailureCount:failureCount]];
			if (failureCount == 1) [self postFailureNotificationForURL:url error:error];
			return;
		}
		[self.failureCounts removeObjectForKey:key];
		self.nextFetchDates[key] = [[NSDate date] dateByAddingTimeInterval:(NSTimeInterval)[PBGitDefaults autoFetchIntervalMinutes] * 60.0];
		[self refreshOpenRepositoryAtURL:url];
		if (advances.count && [PBGitDefaults notifyAboutFetchedCommitsForRepositoryURL:url]) {
			[self postAdvanceNotificationForURL:url advances:advances];
		}
	});
}

- (PBGitRepositoryDocument *)openDocumentForRepositoryURL:(NSURL *)url
{
	NSString *key = [self keyForURL:url];
	for (NSDocument *candidate in [NSDocumentController sharedDocumentController].documents) {
		if (![candidate isKindOfClass:PBGitRepositoryDocument.class]) continue;
		NSURL *candidateURL = [(PBGitRepositoryDocument *)candidate repository].workingDirectoryURL;
		if ([[self keyForURL:candidateURL] isEqualToString:key]) return (PBGitRepositoryDocument *)candidate;
	}
	return nil;
}

- (void)refreshOpenRepositoryAtURL:(NSURL *)url
{
	PBGitRepository *repository = [self openDocumentForRepositoryURL:url].repository;
	[repository reloadRefs];
	[repository forceUpdateRevisions];
}

- (void)postFailureNotificationForURL:(NSURL *)url error:(NSError *)error
{
	UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
	content.title = [NSString stringWithFormat:@"Auto-fetch failed for %@", url.lastPathComponent];
	NSString *reason = error.localizedFailureReason ?: error.localizedDescription ?:
																					@"Git could not refresh this repository.";
	content.body = [reason stringByAppendingString:@" GitX will retry automatically."];
	content.sound = [UNNotificationSound defaultSound];
	content.userInfo = @{@"repository" : url.path ?: @"", @"kind" : @"failure"};
	UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[NSString stringWithFormat:@"gitx-fetch-failure-%@", [self keyForURL:url]] content:content trigger:nil];
	[[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)postAdvanceNotificationForURL:(NSURL *)url advances:(NSArray<NSDictionary *> *)advances
{
	NSInteger total = 0;
	NSMutableArray<NSString *> *summaries = [NSMutableArray array];
	NSDictionary *newest = advances.firstObject;
	for (NSDictionary *advance in advances) {
		NSInteger count = [advance[@"count"] integerValue];
		total += count;
		NSString *branch = [advance[@"ref"] stringByReplacingOccurrencesOfString:@"refs/remotes/" withString:@""];
		[summaries addObject:[NSString stringWithFormat:@"%@ (+%ld)", branch, (long)count]];
		if ([advance[@"timestamp"] doubleValue] > [newest[@"timestamp"] doubleValue]) newest = advance;
	}
	UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
	content.title = [NSString stringWithFormat:@"%@ fetched %ld new commit%@", url.lastPathComponent, (long)total, total == 1 ? @"" : @"s"];
	content.body = [summaries componentsJoinedByString:@", "];
	content.sound = [UNNotificationSound defaultSound];
	content.userInfo = @{
		@"repository" : url.path ?: @"",
		@"kind" : @"advance",
		@"sha" : newest[@"sha"] ?: @"",
		@"ref" : newest[@"ref"] ?: @"",
		@"multipleBranches" : @(advances.count > 1),
	};
	UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[NSString stringWithFormat:@"gitx-fetch-advance-%@-%@", [self keyForURL:url], NSUUID.UUID.UUIDString] content:content trigger:nil];
	[[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)recordManualFetchSucceededForRepositoryURL:(NSURL *)repositoryURL
{
	NSString *key = [self keyForURL:repositoryURL];
	[self.failureCounts removeObjectForKey:key];
	self.nextFetchDates[key] = [[NSDate date] dateByAddingTimeInterval:(NSTimeInterval)[PBGitDefaults autoFetchIntervalMinutes] * 60.0];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
	didReceiveNotificationResponse:(UNNotificationResponse *)response
			 withCompletionHandler:(void (^)(void))completionHandler
{
	NSDictionary *info = response.notification.request.content.userInfo;
	NSString *path = info[@"repository"];
	if (!path.length) {
		completionHandler();
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
		void (^showDocument)(PBGitRepositoryDocument *) = ^(PBGitRepositoryDocument *document) {
			PBGitWindowController *windowController = document.windowController;
			[windowController showHistoryView:self];
			[windowController.window makeKeyAndOrderFront:self];
			[NSApp activateIgnoringOtherApps:YES];
			if ([info[@"multipleBranches"] boolValue]) {
				document.repository.currentBranchFilter = kGitXAllBranchesFilter;
				[PBGitDefaults setBranchFilter:kGitXAllBranchesFilter];
			} else {
				NSString *refName = info[@"ref"];
				if (refName.length) {
					PBGitRef *ref = [PBGitRef refFromString:refName];
					if ([document.repository refExists:ref]) {
						PBGitRevSpecifier *specifier = [[PBGitRevSpecifier alloc] initWithRef:ref];
						specifier.workingDirectory = document.repository.workingDirectoryURL;
						document.repository.currentBranch = [document.repository addBranch:specifier];
						document.repository.currentBranchFilter = kGitXSelectedBranchFilter;
						[PBGitDefaults setBranchFilter:kGitXSelectedBranchFilter];
					}
				}
			}
			[document.repository forceUpdateRevisions];
			NSString *sha = info[@"sha"];
			if (sha.length) {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					[windowController.historyViewController selectCommit:[GTOID oidWithSHA:sha]];
				});
			}
		};

		PBGitRepositoryDocument *document = [self openDocumentForRepositoryURL:url];
		if (document) {
			showDocument(document);
		} else {
			[[PBRepositoryDocumentController sharedDocumentController] openDocumentWithContentsOfURL:url display:YES completionHandler:^(NSDocument *openedDocument, BOOL alreadyOpen, NSError *error) {
				if ([openedDocument isKindOfClass:PBGitRepositoryDocument.class]) showDocument((PBGitRepositoryDocument *)openedDocument);
			}];
		}
	});
	completionHandler();
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
		 willPresentNotification:(UNNotification *)notification
		   withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
	completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

@end

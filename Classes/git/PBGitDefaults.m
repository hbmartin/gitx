//
//  PBGitDefaults.m
//  GitX
//
//  Created by Jeff Mesnil on 19/10/08.
//  Copyright 2008 Jeff Mesnil (http://jmesnil.net/). All rights reserved.
//

#import "PBGitDefaults.h"
#import "PBHistorySearchController.h"

#define kDefaultVerticalLineLength 50
#define kCommitMessageViewVerticalLineLength @"PBCommitMessageViewVerticalLineLength"
#define kDefaultVerticalBodyLineLength 72
#define kCommitMessageViewVerticalBodyLineLength @"PBCommitMessageViewVerticalBodyLineLength"
#define kCommitMessageViewHasVerticalLine @"PBCommitMessageViewHasVerticalLine"
#define kEnableGist @"PBEnableGist"
#define kEnableGravatar @"PBEnableGravatar"
#define kConfirmPublicGists @"PBConfirmPublicGists"
#define kPublicGist @"PBGistPublic"
#define kShowWhitespaceDifferences @"PBShowWhitespaceDifferences"
#define kOpenCurDirOnLaunch @"PBOpenCurDirOnLaunch"
#define kShowOpenPanelOnLaunch @"PBShowOpenPanelOnLaunch"
#define kShouldCheckoutBranch @"PBShouldCheckoutBranch"
#define kRecentCloneDestination @"PBRecentCloneDestination"
#define kShowStageView @"PBShowStageView"
#define kOpenPreviousDocumentsOnLaunch @"PBOpenPreviousDocumentsOnLaunch"
#define kPreviousDocumentPaths @"PBPreviousDocumentPaths"
#define kBranchFilterState @"PBBranchFilter"
#define kHistorySearchMode @"PBHistorySearchMode"
#define kSuppressedDialogWarnings @"Suppressed Dialog Warnings"
#define kUseRepositoryWatcher @"PBUseRepositoryWatcher"
#define kTerminalHandler @"PBTerminalHandler"
#define kAppearancePreference @"PBAppearancePreference"
#define kHistoryColumnSortingEnabled @"PBHistoryColumnSortingEnabled"
#define kAutoFetchScope @"PBAutoFetchScope"
#define kAutoFetchIntervalMinutes @"PBAutoFetchIntervalMinutes"
#define kAutoFetchRepositoryNotifications @"PBAutoFetchRepositoryNotifications"

NSString *const PBGitHistorySortingPreferenceDidChangeNotification = @"PBGitHistorySortingPreferenceDidChangeNotification";
NSString *const PBAutoFetchPreferencesDidChangeNotification = @"PBAutoFetchPreferencesDidChangeNotification";
NSString *const PBAppearancePreferenceDidChangeNotification = @"PBAppearancePreferenceDidChangeNotification";

@implementation PBGitDefaults

+ (void)initialize
{
	NSMutableDictionary *defaultValues = [NSMutableDictionary dictionary];
	[defaultValues setObject:[NSNumber numberWithInt:kDefaultVerticalLineLength]
					  forKey:kCommitMessageViewVerticalLineLength];
	[defaultValues setObject:[NSNumber numberWithInt:kDefaultVerticalBodyLineLength]
					  forKey:kCommitMessageViewVerticalBodyLineLength];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kCommitMessageViewHasVerticalLine];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kEnableGist];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kEnableGravatar];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kConfirmPublicGists];
	[defaultValues setObject:[NSNumber numberWithBool:NO]
					  forKey:kPublicGist];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kShowWhitespaceDifferences];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kOpenCurDirOnLaunch];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kShowOpenPanelOnLaunch];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kShouldCheckoutBranch];
	[defaultValues setObject:[NSNumber numberWithBool:NO]
					  forKey:kOpenPreviousDocumentsOnLaunch];
	[defaultValues setObject:[NSNumber numberWithInteger:PBHistorySearchModeBasic]
					  forKey:kHistorySearchMode];
	[defaultValues setObject:[NSNumber numberWithBool:YES]
					  forKey:kUseRepositoryWatcher];
	[defaultValues setObject:@"com.apple.Terminal"
					  forKey:kTerminalHandler];
	[defaultValues setObject:@(PBAppearancePreferenceAutomatic) forKey:kAppearancePreference];
	[defaultValues setObject:@YES forKey:kHistoryColumnSortingEnabled];
	[defaultValues setObject:@(PBAutoFetchScopeNone) forKey:kAutoFetchScope];
	[defaultValues setObject:@15 forKey:kAutoFetchIntervalMinutes];
	[defaultValues setObject:@{} forKey:kAutoFetchRepositoryNotifications];
	[[NSUserDefaults standardUserDefaults] registerDefaults:defaultValues];
}

+ (NSInteger)commitMessageViewVerticalLineLength
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kCommitMessageViewVerticalLineLength];
}

+ (BOOL)commitMessageViewHasVerticalLine
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kCommitMessageViewHasVerticalLine];
}

+ (NSInteger)commitMessageViewVerticalBodyLineLength
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kCommitMessageViewVerticalBodyLineLength];
}

+ (BOOL)isGistEnabled
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kEnableGist];
}

+ (BOOL)isGravatarEnabled
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kEnableGravatar];
}

+ (BOOL)confirmPublicGists
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kConfirmPublicGists];
}

+ (BOOL)isGistPublic
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kPublicGist];
}

+ (BOOL)showWhitespaceDifferences
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kShowWhitespaceDifferences];
}

+ (BOOL)openCurDirOnLaunch
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kOpenCurDirOnLaunch];
}

+ (BOOL)showOpenPanelOnLaunch
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kShowOpenPanelOnLaunch];
}

+ (BOOL)shouldCheckoutBranch
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kShouldCheckoutBranch];
}

+ (void)setShouldCheckoutBranch:(BOOL)shouldCheckout
{
	[[NSUserDefaults standardUserDefaults] setBool:shouldCheckout forKey:kShouldCheckoutBranch];
}

+ (NSString *)recentCloneDestination
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:kRecentCloneDestination];
}

+ (void)setRecentCloneDestination:(NSString *)path
{
	[[NSUserDefaults standardUserDefaults] setObject:path forKey:kRecentCloneDestination];
}

+ (BOOL)showStageView
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kShowStageView];
}

+ (void)setShowStageView:(BOOL)suppress
{
	return [[NSUserDefaults standardUserDefaults] setBool:suppress forKey:kShowStageView];
}

+ (BOOL)openPreviousDocumentsOnLaunch
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kOpenPreviousDocumentsOnLaunch];
}

+ (void)setPreviousDocumentPaths:(NSArray *)documentPaths
{
	[[NSUserDefaults standardUserDefaults] setObject:documentPaths forKey:kPreviousDocumentPaths];
}

+ (NSArray *)previousDocumentPaths
{
	return [[NSUserDefaults standardUserDefaults] arrayForKey:kPreviousDocumentPaths];
}

+ (void)removePreviousDocumentPaths
{
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kPreviousDocumentPaths];
}
+ (NSInteger)branchFilter
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kBranchFilterState];
}

+ (void)setBranchFilter:(NSInteger)state
{
	[[NSUserDefaults standardUserDefaults] setInteger:state forKey:kBranchFilterState];
}

+ (NSInteger)historySearchMode
{
	return [[NSUserDefaults standardUserDefaults] integerForKey:kHistorySearchMode];
}

+ (void)setHistorySearchMode:(NSInteger)mode
{
	[[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kHistorySearchMode];
}


// Suppressed Dialog Warnings
//
// Represents dialogs where the user has checked the "Do not show this message again" checkbox.
// Keep these together in an array to make it easier to reset all the warnings.

+ (NSSet *)suppressedDialogWarnings
{
	NSSet *suppressedDialogWarnings = [NSSet setWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:kSuppressedDialogWarnings]];
	if (suppressedDialogWarnings == nil)
		suppressedDialogWarnings = [NSSet set];

	return suppressedDialogWarnings;
}

+ (void)suppressDialogWarningForDialog:(NSString *)dialog
{
	NSSet *suppressedDialogWarnings = [[self suppressedDialogWarnings] setByAddingObject:dialog];

	[[NSUserDefaults standardUserDefaults] setObject:[suppressedDialogWarnings allObjects] forKey:kSuppressedDialogWarnings];
}

+ (BOOL)isDialogWarningSuppressedForDialog:(NSString *)dialog
{
	return [[self suppressedDialogWarnings] containsObject:dialog];
}

+ (void)resetAllDialogWarnings
{
	[[NSUserDefaults standardUserDefaults] setObject:nil forKey:kSuppressedDialogWarnings];
	[[NSUserDefaults standardUserDefaults] synchronize];
}


+ (BOOL)useRepositoryWatcher
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kUseRepositoryWatcher];
}

+ (NSString *)terminalHandler
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:kTerminalHandler];
}

+ (PBAppearancePreference)appearancePreference
{
	NSInteger preference = [[NSUserDefaults standardUserDefaults] integerForKey:kAppearancePreference];
	return (preference >= PBAppearancePreferenceAutomatic && preference <= PBAppearancePreferenceDark) ? preference : PBAppearancePreferenceAutomatic;
}

+ (void)setAppearancePreference:(PBAppearancePreference)preference
{
	PBAppearancePreference validatedPreference =
		(preference >= PBAppearancePreferenceAutomatic && preference <= PBAppearancePreferenceDark) ? preference : PBAppearancePreferenceAutomatic;
	[[NSUserDefaults standardUserDefaults] setInteger:validatedPreference forKey:kAppearancePreference];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBAppearancePreferenceDidChangeNotification object:nil];
}

+ (BOOL)historyColumnSortingEnabled
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kHistoryColumnSortingEnabled];
}

+ (void)setHistoryColumnSortingEnabled:(BOOL)enabled
{
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kHistoryColumnSortingEnabled];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitHistorySortingPreferenceDidChangeNotification object:nil];
}

+ (PBAutoFetchScope)autoFetchScope
{
	NSInteger scope = [[NSUserDefaults standardUserDefaults] integerForKey:kAutoFetchScope];
	return (scope >= PBAutoFetchScopeNone && scope <= PBAutoFetchScopeOpenAndRecentRepositories) ? scope : PBAutoFetchScopeNone;
}

+ (void)setAutoFetchScope:(PBAutoFetchScope)scope
{
	[[NSUserDefaults standardUserDefaults] setInteger:scope forKey:kAutoFetchScope];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBAutoFetchPreferencesDidChangeNotification object:nil];
}

+ (NSInteger)autoFetchIntervalMinutes
{
	NSInteger interval = [[NSUserDefaults standardUserDefaults] integerForKey:kAutoFetchIntervalMinutes];
	return MAX(1, MIN(1440, interval));
}

+ (void)setAutoFetchIntervalMinutes:(NSInteger)minutes
{
	[[NSUserDefaults standardUserDefaults] setInteger:MAX(1, MIN(1440, minutes)) forKey:kAutoFetchIntervalMinutes];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBAutoFetchPreferencesDidChangeNotification object:nil];
}

+ (NSString *)repositoryDefaultsKeyForURL:(NSURL *)repositoryURL
{
	return repositoryURL.URLByStandardizingPath.path ?: repositoryURL.path ?: @"";
}

+ (BOOL)notifyAboutFetchedCommitsForRepositoryURL:(NSURL *)repositoryURL
{
	NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAutoFetchRepositoryNotifications];
	return [settings[[self repositoryDefaultsKeyForURL:repositoryURL]] boolValue];
}

+ (void)setNotifyAboutFetchedCommits:(BOOL)enabled forRepositoryURL:(NSURL *)repositoryURL
{
	NSMutableDictionary *settings = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kAutoFetchRepositoryNotifications] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *key = [self repositoryDefaultsKeyForURL:repositoryURL];
	if (key.length) settings[key] = @(enabled);
	[[NSUserDefaults standardUserDefaults] setObject:settings forKey:kAutoFetchRepositoryNotifications];
}

@end

//
//  PBGitDefaults.m
//  GitX
//
//  Created by Jeff Mesnil on 19/10/08.
//  Copyright 2008 Jeff Mesnil (http://jmesnil.net/). All rights reserved.
//

#import "PBGitDefaults.h"
#import "PBHistorySearchController.h"
#import "GitX-Swift.h"

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

static PBApplicationPreferences *PBPreferences(void)
{
	return [PBApplicationComposition sharedComposition].applicationPreferences;
}

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
	[PBPreferences() registerDefaults:defaultValues];
}

+ (NSInteger)commitMessageViewVerticalLineLength
{
	return [PBPreferences() integerForKey:kCommitMessageViewVerticalLineLength];
}

+ (BOOL)commitMessageViewHasVerticalLine
{
	return [PBPreferences() boolForKey:kCommitMessageViewHasVerticalLine];
}

+ (NSInteger)commitMessageViewVerticalBodyLineLength
{
	return [PBPreferences() integerForKey:kCommitMessageViewVerticalBodyLineLength];
}

+ (BOOL)isGistEnabled
{
	return [PBPreferences() boolForKey:kEnableGist];
}

+ (BOOL)isGravatarEnabled
{
	return [PBPreferences() boolForKey:kEnableGravatar];
}

+ (BOOL)confirmPublicGists
{
	return [PBPreferences() boolForKey:kConfirmPublicGists];
}

+ (BOOL)isGistPublic
{
	return [PBPreferences() boolForKey:kPublicGist];
}

+ (BOOL)showWhitespaceDifferences
{
	return [PBPreferences() boolForKey:kShowWhitespaceDifferences];
}

+ (BOOL)openCurDirOnLaunch
{
	return [PBPreferences() boolForKey:kOpenCurDirOnLaunch];
}

+ (BOOL)showOpenPanelOnLaunch
{
	return [PBPreferences() boolForKey:kShowOpenPanelOnLaunch];
}

+ (BOOL)shouldCheckoutBranch
{
	return [PBPreferences() boolForKey:kShouldCheckoutBranch];
}

+ (void)setShouldCheckoutBranch:(BOOL)shouldCheckout
{
	[PBPreferences() setBool:shouldCheckout forKey:kShouldCheckoutBranch];
}

+ (NSString *)recentCloneDestination
{
	return [PBPreferences() stringForKey:kRecentCloneDestination];
}

+ (void)setRecentCloneDestination:(NSString *)path
{
	[PBPreferences() setObject:path forKey:kRecentCloneDestination];
}

+ (BOOL)showStageView
{
	return [PBPreferences() boolForKey:kShowStageView];
}

+ (void)setShowStageView:(BOOL)suppress
{
	[PBPreferences() setBool:suppress forKey:kShowStageView];
}

+ (BOOL)openPreviousDocumentsOnLaunch
{
	return [PBPreferences() boolForKey:kOpenPreviousDocumentsOnLaunch];
}

+ (void)setPreviousDocumentPaths:(NSArray *)documentPaths
{
	[PBPreferences() setObject:documentPaths forKey:kPreviousDocumentPaths];
}

+ (NSArray *)previousDocumentPaths
{
	return [PBPreferences() arrayForKey:kPreviousDocumentPaths];
}

+ (void)removePreviousDocumentPaths
{
	[PBPreferences() removeObjectForKey:kPreviousDocumentPaths];
}
+ (NSInteger)branchFilter
{
	return [PBPreferences() integerForKey:kBranchFilterState];
}

+ (void)setBranchFilter:(NSInteger)state
{
	[PBPreferences() setInteger:state forKey:kBranchFilterState];
}

+ (NSInteger)historySearchMode
{
	return [PBPreferences() integerForKey:kHistorySearchMode];
}

+ (void)setHistorySearchMode:(NSInteger)mode
{
	[PBPreferences() setInteger:mode forKey:kHistorySearchMode];
}


// Suppressed Dialog Warnings
//
// Represents dialogs where the user has checked the "Do not show this message again" checkbox.
// Keep these together in an array to make it easier to reset all the warnings.

+ (NSSet *)suppressedDialogWarnings
{
	NSSet *suppressedDialogWarnings = [NSSet setWithArray:[PBPreferences() arrayForKey:kSuppressedDialogWarnings]];
	if (suppressedDialogWarnings == nil)
		suppressedDialogWarnings = [NSSet set];

	return suppressedDialogWarnings;
}

+ (void)suppressDialogWarningForDialog:(NSString *)dialog
{
	NSSet *suppressedDialogWarnings = [[self suppressedDialogWarnings] setByAddingObject:dialog];

	[PBPreferences() setObject:[suppressedDialogWarnings allObjects] forKey:kSuppressedDialogWarnings];
}

+ (BOOL)isDialogWarningSuppressedForDialog:(NSString *)dialog
{
	return [[self suppressedDialogWarnings] containsObject:dialog];
}

+ (void)resetAllDialogWarnings
{
	[PBPreferences() setObject:nil forKey:kSuppressedDialogWarnings];
	[PBPreferences() synchronize];
}


+ (BOOL)useRepositoryWatcher
{
	return [PBPreferences() boolForKey:kUseRepositoryWatcher];
}

+ (NSString *)terminalHandler
{
	return [PBPreferences() stringForKey:kTerminalHandler];
}

+ (PBAppearancePreference)appearancePreference
{
	NSInteger preference = [PBPreferences() integerForKey:kAppearancePreference];
	return (preference >= PBAppearancePreferenceAutomatic && preference <= PBAppearancePreferenceDark) ? preference : PBAppearancePreferenceAutomatic;
}

+ (void)setAppearancePreference:(PBAppearancePreference)preference
{
	PBAppearancePreference validatedPreference =
		(preference >= PBAppearancePreferenceAutomatic && preference <= PBAppearancePreferenceDark) ? preference : PBAppearancePreferenceAutomatic;
	[PBPreferences() setInteger:validatedPreference forKey:kAppearancePreference];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBAppearancePreferenceDidChangeNotification object:nil];
}

+ (BOOL)historyColumnSortingEnabled
{
	return [PBPreferences() boolForKey:kHistoryColumnSortingEnabled];
}

+ (void)setHistoryColumnSortingEnabled:(BOOL)enabled
{
	[PBPreferences() setBool:enabled forKey:kHistoryColumnSortingEnabled];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBGitHistorySortingPreferenceDidChangeNotification object:nil];
}

+ (PBAutoFetchScope)autoFetchScope
{
	NSInteger scope = [PBPreferences() integerForKey:kAutoFetchScope];
	return (scope >= PBAutoFetchScopeNone && scope <= PBAutoFetchScopeOpenAndRecentRepositories) ? scope : PBAutoFetchScopeNone;
}

+ (void)setAutoFetchScope:(PBAutoFetchScope)scope
{
	PBAutoFetchScope validatedScope = (PBAutoFetchScope)[PBGitDefaultsPolicy validatedAutoFetchScopeRawValue:scope];
	[PBPreferences() setInteger:validatedScope forKey:kAutoFetchScope];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBAutoFetchPreferencesDidChangeNotification object:nil];
}

+ (NSInteger)autoFetchIntervalMinutes
{
	NSInteger interval = [PBPreferences() integerForKey:kAutoFetchIntervalMinutes];
	return MAX(1, MIN(1440, interval));
}

+ (void)setAutoFetchIntervalMinutes:(NSInteger)minutes
{
	[PBPreferences() setInteger:MAX(1, MIN(1440, minutes)) forKey:kAutoFetchIntervalMinutes];
	[[NSNotificationCenter defaultCenter] postNotificationName:PBAutoFetchPreferencesDidChangeNotification object:nil];
}

+ (NSString *)repositoryDefaultsKeyForURL:(NSURL *)repositoryURL
{
	return [PBGitDefaultsPolicy repositoryDefaultsKeyForURL:repositoryURL];
}

+ (BOOL)notifyAboutFetchedCommitsForRepositoryURL:(NSURL *)repositoryURL
{
	NSDictionary *settings = [PBPreferences() dictionaryForKey:kAutoFetchRepositoryNotifications];
	return [settings[[self repositoryDefaultsKeyForURL:repositoryURL]] boolValue];
}

+ (void)setNotifyAboutFetchedCommits:(BOOL)enabled forRepositoryURL:(NSURL *)repositoryURL
{
	NSMutableDictionary *settings = [[PBPreferences() dictionaryForKey:kAutoFetchRepositoryNotifications] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *key = [self repositoryDefaultsKeyForURL:repositoryURL];
	if (key.length) settings[key] = @(enabled);
	[PBPreferences() setObject:settings forKey:kAutoFetchRepositoryNotifications];
}

@end

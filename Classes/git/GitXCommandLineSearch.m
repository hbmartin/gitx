//
//  GitXCommandLineSearch.m
//  GitX
//

#import "GitXCommandLineSearch.h"

static NSString *const GitXShortBasicSearch = @"-s";
static NSString *const GitXBasicSearch = @"--search=";
static NSString *const GitXShortPickaxeSearch = @"-S";
static NSString *const GitXPickaxeSearch = @"--Search=";
static NSString *const GitXShortRegexSearch = @"-r";
static NSString *const GitXRegexSearch = @"--regex=";
static NSString *const GitXShortPathSearch = @"-p";
static NSString *const GitXPathSearch = @"--path=";

NSArray<NSString *> *GitXCommandLineSearchPrefixes(void)
{
	return @[ GitXShortBasicSearch, GitXBasicSearch, GitXShortPickaxeSearch, GitXPickaxeSearch,
			  GitXShortRegexSearch, GitXRegexSearch, GitXShortPathSearch, GitXPathSearch ];
}

PBHistorySearchMode GitXCommandLineSearchModeForArgument(NSString *argument)
{
	if ([argument hasPrefix:GitXShortBasicSearch] || [argument hasPrefix:GitXBasicSearch])
		return PBHistorySearchModeBasic;

	if ([argument hasPrefix:GitXShortPickaxeSearch] || [argument hasPrefix:GitXPickaxeSearch])
		return PBHistorySearchModePickaxe;

	if ([argument hasPrefix:GitXShortRegexSearch] || [argument hasPrefix:GitXRegexSearch])
		return PBHistorySearchModeRegex;

	if ([argument hasPrefix:GitXShortPathSearch] || [argument hasPrefix:GitXPathSearch])
		return PBHistorySearchModePath;

	return 0;
}

static NSString *GitXCommandLineSearchRemovingPrefix(NSString *string)
{
	for (NSString *prefix in GitXCommandLineSearchPrefixes()) {
		if ([string hasPrefix:prefix])
			return [string substringFromIndex:prefix.length];
	}
	return string;
}

NSString *GitXCommandLineSearchQuotedArgument(NSString *argument)
{
	static NSCharacterSet *special;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableCharacterSet *characters = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
		[characters addCharactersInString:@"'\"\\"];
		special = [characters copy];
	});
	if (argument.length > 0 && [argument rangeOfCharacterFromSet:special].location == NSNotFound)
		return argument;
	NSString *escaped = [argument stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
	return [NSString stringWithFormat:@"'%@'", escaped];
}

NSString *GitXCommandLineSearchQuery(NSArray<NSString *> *arguments, PBHistorySearchMode mode)
{
	if (mode != PBHistorySearchModePath && mode != PBHistorySearchModeRaw)
		return GitXCommandLineSearchRemovingPrefix([arguments componentsJoinedByString:@" "]);

	NSMutableArray<NSString *> *terms = [arguments mutableCopy];
	if (terms.count > 0) {
		terms[0] = GitXCommandLineSearchRemovingPrefix(terms[0]);
		if (terms[0].length == 0)
			[terms removeObjectAtIndex:0];
	}
	NSMutableArray<NSString *> *quoted = [NSMutableArray arrayWithCapacity:terms.count];
	for (NSString *term in terms)
		[quoted addObject:GitXCommandLineSearchQuotedArgument(term)];
	return [quoted componentsJoinedByString:@" "];
}

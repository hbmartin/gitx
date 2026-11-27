//
//  GitXCommandLineSearch.h
//  GitX
//
//  Shared by the app and the gitx command-line tool so the history search a
//  CLI invocation requests is exactly the one GitX parses.
//

#import <Foundation/Foundation.h>
#import "PBHistorySearchMode.h"

NS_ASSUME_NONNULL_BEGIN

/// The search flags `gitx` accepts, short forms before their long forms. `--raw-search=` has no short form.
NSArray<NSString *> *GitXCommandLineSearchPrefixes(void);

/// The history search mode a leading CLI argument selects, or 0 when it is not a search flag.
PBHistorySearchMode GitXCommandLineSearchModeForArgument(NSString *argument);

/// The saved search name a `--saved-search=` invocation asks for: the rest of the first argument and any
/// further arguments, joined by spaces and trimmed. Nil when the first argument is not `--saved-search=`.
NSString *_Nullable GitXCommandLineSavedSearchName(NSArray<NSString *> *arguments);

/// Single-quotes `argument` for the history search tokenizer unless it is non-empty and
/// contains no whitespace, quote, or backslash.
NSString *GitXCommandLineSearchQuotedArgument(NSString *argument);

/// The history search query for the shell-split `arguments` that follow `gitx`, with any
/// leading search flag removed. Path and raw searches quote each argument so GitX's
/// tokenizer recovers the exact arguments the shell passed; other modes search for the
/// arguments joined by spaces.
NSString *GitXCommandLineSearchQuery(NSArray<NSString *> *arguments, PBHistorySearchMode mode);

NS_ASSUME_NONNULL_END

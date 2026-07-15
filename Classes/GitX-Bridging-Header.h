//
//  GitX-Bridging-Header.h
//  GitX
//
//  Exposes Objective-C headers to Swift.
//
//  RULE: only add a header here when a Swift file actually needs to reference
//  the type/symbol.  Do NOT bulk-import everything — it breaks archive builds.
//  External/ headers are imported via framework imports only (no bare filenames).
//

// ── System ───────────────────────────────────────────────────────────────────
#import <Cocoa/Cocoa.h>

// ── External frameworks (framework imports only — no bare filenames) ──────────
#import <ObjectiveGit/ObjectiveGit.h>

// ── Converted files: headers kept so ObjC callers continue to compile ────────
// Swift callers use the Objective-C dark-mode compatibility category.
#import "NSAppearance+PBDarkMode.h"
// NSColor+RGB.swift owns the implementation.
#import "NSColor+RGB.h"
// NSSplitView+GitX.swift owns the implementation.
#import "NSSplitView+GitX.h"
// GitXRelativeDateFormatter.swift owns the implementation.
#import "GitXRelativeDateFormatter.h"
// PBHistoryArrayController.swift owns the implementation.
#import "PBHistoryArrayController.h"

// ── Add further headers below only when a Swift source file needs them ────────
// PBCommitList.swift needs these:
#import "PBMacros.h"
#import "PBCommitList.h"
#import "PBGitRevisionCell.h"
#import "PBWebHistoryController.h"
#import "PBHistorySearchController.h"
#import "PBGitHistoryController.h"
#import "PBGitCommit.h"
#import "PBGitRef.h"
#import "PBHighlighting.h"
#import "PBGitDefaults.h"

// The bridging header declares no APIs of its own, but retain an explicit
// nullability region so it follows the same interoperability contract as
// first-party declaration headers.
NS_ASSUME_NONNULL_BEGIN
NS_ASSUME_NONNULL_END

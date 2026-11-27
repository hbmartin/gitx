//
//  GitXRelativeDateFormatter.swift
//  GitX
//
//  Originally GitXRelativeDateFormatter.m by Nathan Kinsinger, Copyright 2010.
//

import Foundation
import GitXCore

/// Formats the history list's relative-date column. `RelativeDatePolicy` owns classification and wording;
/// this adapter keeps the Objective-C class name that `PBGitHistoryView.xib` instantiates.
@objc(GitXRelativeDateFormatter)
final nonisolated class GitXRelativeDateFormatter: Formatter {
    /// The reference instant for each description. Tests inject a fixed clock.
    var now: () -> Date = { Date() }
    /// Follows the user's current calendar and time zone, including changes made while GitX runs.
    var calendar: Calendar = .autoupdatingCurrent

    override func string(for obj: Any?) -> String? {
        guard let date = obj as? Date else { return nil }
        return RelativeDatePolicy.englishDescription(of: date, now: now(), calendar: calendar)
    }
}

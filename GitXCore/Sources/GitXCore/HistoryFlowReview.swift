import Foundation

/// How the Flow tab shows the selected function.
public enum HistoryFlowPresentation: String, CaseIterable, Sendable {
    case delta
    case beforeAfter = "before-after"
    case calls
}

/// Which way a Flow slice follows causality from the selected node.
public enum HistoryFlowSliceDirection: String, CaseIterable, Sendable {
    case forward
    case backward
}

/// Which cosmetic node changes the Flow tab shows as unchanged. Raw values match FlowDelta's noise policy.
public enum HistoryFlowNoiseLevel: String, CaseIterable, Sendable {
    case showAll = "show-all"
    case hideFormatting = "hide-formatting"
    case hideCosmetic = "hide-cosmetic"

    public var menuTitle: String {
        switch self {
        case .showAll: "Show All Changes"
        case .hideFormatting: "Hide Formatting"
        case .hideCosmetic: "Hide Cosmetic Changes"
        }
    }
}

/// A Flow report format GitX can copy or export.
public enum HistoryFlowExportFormat: String, CaseIterable, Sendable {
    case markdown
    case json
    case mermaid

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        case .mermaid: "Mermaid"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .json: "json"
        case .mermaid: "mmd"
        }
    }
}

/// The Flow review choices GitX remembers across commits, windows and launches.
public struct HistoryFlowReviewPreferences: Equatable, Sendable {
    public var presentation: HistoryFlowPresentation
    /// The slice direction, or nil when no slice is shown.
    public var slice: HistoryFlowSliceDirection?
    public var noise: HistoryFlowNoiseLevel
    public var groupsByConcern: Bool
    public var exportFormat: HistoryFlowExportFormat

    /// Cosmetic noise is hidden by default; its count stays visible as an "N hidden — Show" link.
    public static let `default` = HistoryFlowReviewPreferences(
        presentation: .delta,
        slice: nil,
        noise: .hideCosmetic,
        groupsByConcern: false,
        exportFormat: .markdown
    )

    private static let noSlice = "none"

    public init(
        presentation: HistoryFlowPresentation,
        slice: HistoryFlowSliceDirection?,
        noise: HistoryFlowNoiseLevel,
        groupsByConcern: Bool,
        exportFormat: HistoryFlowExportFormat
    ) {
        self.presentation = presentation
        self.slice = slice
        self.noise = noise
        self.groupsByConcern = groupsByConcern
        self.exportFormat = exportFormat
    }

    /// Reads stored values, keeping the default for any value that is missing, of the wrong type or unknown.
    public init(reading value: (ApplicationPreferenceKey) -> Any?) {
        let fallback = Self.default
        presentation = (value(.historyFlowPresentation) as? String)
            .flatMap(HistoryFlowPresentation.init(rawValue:)) ?? fallback.presentation
        if let stored = value(.historyFlowSliceDirection) as? String, stored != Self.noSlice {
            slice = HistoryFlowSliceDirection(rawValue: stored) ?? fallback.slice
        } else {
            slice = fallback.slice
        }
        noise = (value(.historyFlowNoiseLevel) as? String)
            .flatMap(HistoryFlowNoiseLevel.init(rawValue:)) ?? fallback.noise
        groupsByConcern = (value(.historyFlowGroupsByConcern) as? Bool) ?? fallback.groupsByConcern
        exportFormat = (value(.historyFlowExportFormat) as? String)
            .flatMap(HistoryFlowExportFormat.init(rawValue:)) ?? fallback.exportFormat
    }

    /// The values to store, as property-list strings and Booleans.
    public var storedValues: [(key: ApplicationPreferenceKey, value: HistoryFlowStoredValue)] {
        [
            (.historyFlowPresentation, .string(presentation.rawValue)),
            (.historyFlowSliceDirection, .string(slice?.rawValue ?? Self.noSlice)),
            (.historyFlowNoiseLevel, .string(noise.rawValue)),
            (.historyFlowGroupsByConcern, .bool(groupsByConcern)),
            (.historyFlowExportFormat, .string(exportFormat.rawValue)),
        ]
    }
}

/// A property-list value for one Flow review preference.
public enum HistoryFlowStoredValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
}

/// A Flow Review menu command.
public enum HistoryFlowCommand: Equatable, Sendable {
    case presentation(HistoryFlowPresentation)
    case slice(HistoryFlowSliceDirection)
    case noise(HistoryFlowNoiseLevel)
    case toggleGroupByConcern
    case startWalkthrough
    case nextWalkthroughStep
    case previousWalkthroughStep
    case copyReport(HistoryFlowExportFormat)
    case exportReport

    /// Menu items carry their command as a tag, so one action serves the whole Flow Review menu.
    public var tag: Int {
        switch self {
        case .presentation(.delta): 100
        case .presentation(.beforeAfter): 101
        case .presentation(.calls): 102
        case .slice(.forward): 110
        case .slice(.backward): 111
        case .noise(.showAll): 120
        case .noise(.hideFormatting): 121
        case .noise(.hideCosmetic): 122
        case .toggleGroupByConcern: 130
        case .startWalkthrough: 140
        case .nextWalkthroughStep: 141
        case .previousWalkthroughStep: 142
        case .copyReport(.markdown): 150
        case .copyReport(.json): 151
        case .copyReport(.mermaid): 152
        case .exportReport: 160
        }
    }

    public init?(tag: Int) {
        guard let command = Self.all.first(where: { $0.tag == tag }) else { return nil }
        self = command
    }

    public static let all: [HistoryFlowCommand] =
        HistoryFlowPresentation.allCases.map(Self.presentation)
            + HistoryFlowSliceDirection.allCases.map(Self.slice)
            + HistoryFlowNoiseLevel.allCases.map(Self.noise)
            + [.toggleGroupByConcern, .startWalkthrough, .nextWalkthroughStep, .previousWalkthroughStep]
            + HistoryFlowExportFormat.allCases.map(Self.copyReport)
            + [.exportReport]
}

/// What the Flow tab shows, as far as its menu commands care.
public struct HistoryFlowCommandContext: Equatable, Sendable {
    /// Whether the Flow tab is visible and shows a report.
    public var hasReport: Bool
    /// Whether a callable function is selected, so presentations and slices apply.
    public var hasFunction: Bool
    /// Whether a node is selected, so a slice has a node to start from.
    public var hasSelectedNode: Bool
    public var presentation: HistoryFlowPresentation
    public var slice: HistoryFlowSliceDirection?
    public var noise: HistoryFlowNoiseLevel
    public var groupsByConcern: Bool
    /// Whether the report has function changes to walk through. The review explains when none are visible.
    public var canStartWalkthrough: Bool
    /// The step on screen, or nil when no walkthrough is running.
    public var walkthroughStep: Int?
    /// How many steps the running walkthrough has.
    public var walkthroughStepCount: Int

    public init(
        hasReport: Bool,
        hasFunction: Bool,
        hasSelectedNode: Bool,
        presentation: HistoryFlowPresentation,
        slice: HistoryFlowSliceDirection?,
        noise: HistoryFlowNoiseLevel,
        groupsByConcern: Bool,
        canStartWalkthrough: Bool,
        walkthroughStep: Int?,
        walkthroughStepCount: Int
    ) {
        self.hasReport = hasReport
        self.hasFunction = hasFunction
        self.hasSelectedNode = hasSelectedNode
        self.presentation = presentation
        self.slice = slice
        self.noise = noise
        self.groupsByConcern = groupsByConcern
        self.canStartWalkthrough = canStartWalkthrough
        self.walkthroughStep = walkthroughStep
        self.walkthroughStepCount = walkthroughStepCount
    }

    /// The context of a Flow tab that is hidden or shows no report.
    public static let unavailable = HistoryFlowCommandContext(
        hasReport: false,
        hasFunction: false,
        hasSelectedNode: false,
        presentation: .delta,
        slice: nil,
        noise: .showAll,
        groupsByConcern: false,
        canStartWalkthrough: false,
        walkthroughStep: nil,
        walkthroughStepCount: 0
    )
}

/// Whether a Flow Review menu item is enabled and checked.
public struct HistoryFlowCommandState: Equatable, Sendable {
    public var isEnabled: Bool
    public var isChecked: Bool

    public init(isEnabled: Bool, isChecked: Bool) {
        self.isEnabled = isEnabled
        self.isChecked = isChecked
    }
}

public enum HistoryFlowCommandPolicy {
    public static func state(for command: HistoryFlowCommand, in context: HistoryFlowCommandContext)
        -> HistoryFlowCommandState
    {
        guard context.hasReport else { return HistoryFlowCommandState(isEnabled: false, isChecked: false) }
        switch command {
        case let .presentation(presentation):
            return HistoryFlowCommandState(
                isEnabled: context.hasFunction,
                isChecked: context.hasFunction && context.presentation == presentation
            )
        case let .slice(direction):
            // Slices follow causality from a selected node, in the delta graph only.
            let applies = context.hasFunction && context.hasSelectedNode && context.presentation == .delta
            return HistoryFlowCommandState(isEnabled: applies, isChecked: applies && context.slice == direction)
        case let .noise(level):
            return HistoryFlowCommandState(isEnabled: true, isChecked: context.noise == level)
        case .toggleGroupByConcern:
            return HistoryFlowCommandState(isEnabled: true, isChecked: context.groupsByConcern)
        case .startWalkthrough:
            return HistoryFlowCommandState(
                isEnabled: context.walkthroughStep == nil && context.canStartWalkthrough,
                isChecked: false
            )
        case .nextWalkthroughStep:
            let step = context.walkthroughStep
            return HistoryFlowCommandState(
                isEnabled: step.map { $0 + 1 < context.walkthroughStepCount } ?? false,
                isChecked: false
            )
        case .previousWalkthroughStep:
            return HistoryFlowCommandState(isEnabled: (context.walkthroughStep ?? 0) > 0, isChecked: false)
        case .copyReport, .exportReport:
            return HistoryFlowCommandState(isEnabled: true, isChecked: false)
        }
    }
}

/// Names exported Flow reports after the revisions they compare.
public enum HistoryFlowExportPolicy {
    public static func fileName(base: String, target: String, format: HistoryFlowExportFormat) -> String {
        "Flow \(abbreviated(base))..\(abbreviated(target)).\(format.fileExtension)"
    }

    private static func abbreviated(_ revision: String) -> String {
        let safe = revision.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let text = String(String.UnicodeScalarView(safe))
        return text.isEmpty ? "revision" : String(text.prefix(8))
    }
}

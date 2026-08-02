import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

nonisolated enum ForgeDestinationScriptFamily: String, CaseIterable {
    case repository = "forge repository URL"
    case branch = "forge branch URL"
    case commit = "forge commit URL"
    case file = "forge file URL"
    case compare = "forge compare URL"
    case pullRequest = "forge pull request URL"
    case issue = "forge issue URL"
}

nonisolated struct ForgeDestinationScriptDecision {
    let family: ForgeDestinationScriptFamily
    let request: RepositoryForgeDestinationRequest
}

nonisolated struct ForgeDestinationScriptFailure: Error, Equatable {
    let code: Int
    let message: String

    static let invalidDocument = Self(
        code: 18000,
        message: "The command requires exactly one explicitly identified open GitX repository document."
    )
    static let invalidDestination = Self(
        code: RepositoryForgeScriptingErrorCode.invalidDestination.rawValue,
        message: "The Forge destination parameters are invalid."
    )
    static let invalidExecutionContext = Self(
        code: 18006,
        message: "The Forge destination command must execute on the application's main thread."
    )
}

nonisolated enum ForgeDestinationScriptDecisionPolicy {
    static let documentKey = "document"
    static let branchKey = "branch"
    static let commitKey = "commit"
    static let revisionKey = "revision"
    static let revisionKindKey = "revisionKind"
    static let pathKey = "path"
    static let startLineKey = "startLine"
    static let endLineKey = "endLine"
    static let baseRevisionKey = "baseRevision"
    static let baseRevisionKindKey = "baseRevisionKind"
    static let headRevisionKey = "headRevision"
    static let headRevisionKindKey = "headRevisionKind"
    static let numberKey = "number"

    // These are the `FrBr`, `FrTg`, and `FrCm` enumerator codes in GitX.sdef.
    static let branchRevisionCode: UInt32 = 0x4672_4272
    static let tagRevisionCode: UInt32 = 0x4672_5467
    static let commitRevisionCode: UInt32 = 0x4672_436D

    static func decision(
        commandName: String,
        arguments: [String: Any]
    ) -> Result<ForgeDestinationScriptDecision, ForgeDestinationScriptFailure> {
        guard let family = ForgeDestinationScriptFamily(rawValue: commandName) else {
            return .failure(.invalidDestination)
        }

        let request: RepositoryForgeDestinationRequest?
        switch family {
        case .repository:
            request = .repository
        case .branch:
            request = text(arguments[branchKey]).map(RepositoryForgeDestinationRequest.branch)
        case .commit:
            request = text(arguments[commitKey]).map(RepositoryForgeDestinationRequest.commit)
        case .file:
            request = fileRequest(arguments)
        case .compare:
            request = compareRequest(arguments)
        case .pullRequest:
            request = integer(arguments[numberKey]).map(RepositoryForgeDestinationRequest.pullRequest)
        case .issue:
            request = integer(arguments[numberKey]).map(RepositoryForgeDestinationRequest.issue)
        }

        guard let request else {
            return .failure(.invalidDestination)
        }
        return .success(ForgeDestinationScriptDecision(family: family, request: request))
    }

    private static func fileRequest(_ arguments: [String: Any]) -> RepositoryForgeDestinationRequest? {
        guard let revision = text(arguments[revisionKey]),
              let kind = revisionKind(arguments[revisionKindKey]),
              let path = text(arguments[pathKey]),
              let startLine = optionalInteger(arguments[startLineKey]),
              let endLine = optionalInteger(arguments[endLineKey]),
              startLine != nil || endLine == nil
        else {
            return nil
        }
        return .file(
            revision: revisionRequest(revision, kind: kind),
            path: path,
            startLine: startLine,
            endLine: endLine
        )
    }

    private static func compareRequest(_ arguments: [String: Any]) -> RepositoryForgeDestinationRequest? {
        guard let base = text(arguments[baseRevisionKey]),
              let baseKind = revisionKind(arguments[baseRevisionKindKey]),
              let head = text(arguments[headRevisionKey]),
              let headKind = revisionKind(arguments[headRevisionKindKey])
        else {
            return nil
        }
        return .compare(
            base: revisionRequest(base, kind: baseKind),
            head: revisionRequest(head, kind: headKind)
        )
    }

    private static func revisionRequest(
        _ value: String,
        kind: RepositoryForgeRevisionKind
    ) -> RepositoryForgeRevisionRequest {
        switch kind {
        case .branch: .branch(value)
        case .tag: .tag(value)
        case .commit: .commit(value)
        }
    }

    private static func revisionKind(_ value: Any?) -> RepositoryForgeRevisionKind? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return switch number.uint32Value {
        case branchRevisionCode: RepositoryForgeRevisionKind.branch
        case tagRevisionCode: RepositoryForgeRevisionKind.tag
        case commitRevisionCode: RepositoryForgeRevisionKind.commit
        default: nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func optionalInteger(_ value: Any?) -> Int?? {
        guard let value else { return .some(nil) }
        return integer(value).map(Optional.some)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              !isBoolean(number),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            return nil
        }
        return number.intValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

@MainActor
protocol ForgeDestinationScriptRepositoryResolving {
    func repository(for argument: Any?) -> Result<PBGitRepository, ForgeDestinationScriptFailure>
}

@MainActor
struct OpenForgeDestinationScriptRepositoryResolver: ForgeDestinationScriptRepositoryResolving {
    func repository(for argument: Any?) -> Result<PBGitRepository, ForgeDestinationScriptFailure> {
        let values: [Any]
        if let arguments = argument as? [Any] {
            values = arguments
        } else if let argument {
            values = [argument]
        } else {
            values = []
        }
        guard values.count == 1,
              let document = values[0] as? PBGitRepositoryDocument,
              NSDocumentController.shared.documents.contains(where: { $0 === document })
        else {
            return .failure(.invalidDocument)
        }
        return .success(document.repository)
    }
}

@MainActor
protocol ForgeDestinationScriptURLResolving {
    func url(
        for request: RepositoryForgeDestinationRequest,
        repository: PBGitRepository
    ) -> Result<URL, NSError>
}

@MainActor
struct NativeForgeDestinationScriptURLResolver: ForgeDestinationScriptURLResolving {
    func url(
        for request: RepositoryForgeDestinationRequest,
        repository: PBGitRepository
    ) -> Result<URL, NSError> {
        RepositoryForgeCoordinator(repository: repository).resolveForScripting(request)
    }
}

// swift6-safety-justification: Cocoa Scripting requires an `Any?` return from its nonisolated override.
// The box is created, written, and read synchronously on the verified AppKit main thread.
private final nonisolated class ForgeDestinationScriptResultBox: @unchecked Sendable {
    let command: ForgeDestinationScriptCommand
    var value: Any?

    init(command: ForgeDestinationScriptCommand) {
        self.command = command
    }
}

/// Returns validated provider-native Forge URLs to AppleScript without opening UI or external applications.
@objc(PBForgeDestinationScriptCommand)
final nonisolated class ForgeDestinationScriptCommand: NSScriptCommand {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeScripting")

    @MainActor var repositoryResolver: any ForgeDestinationScriptRepositoryResolving =
        OpenForgeDestinationScriptRepositoryResolver()
    @MainActor var urlResolver: any ForgeDestinationScriptURLResolving = NativeForgeDestinationScriptURLResolver()

    override nonisolated func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread else {
            let failure = ForgeDestinationScriptFailure.invalidExecutionContext
            scriptErrorNumber = failure.code
            scriptErrorString = failure.message
            return nil
        }
        // Cocoa Scripting dispatches application commands on AppKit's main thread.
        let result = ForgeDestinationScriptResultBox(command: self)
        // swift6-safety-justification: the main-thread guard above establishes MainActor execution synchronously.
        MainActor.assumeIsolated {
            result.value = result.command.performOnMainActor()
        }
        return result.value
    }

    @MainActor
    private func performOnMainActor() -> Any? {
        let arguments = evaluatedArguments ?? [:]
        let commandName = commandDescription.commandName
        switch ForgeDestinationScriptDecisionPolicy.decision(
            commandName: commandName,
            arguments: arguments
        ) {
        case let .failure(failure):
            return fail(failure)
        case let .success(decision):
            switch repositoryResolver.repository(for: arguments[ForgeDestinationScriptDecisionPolicy.documentKey]) {
            case let .failure(failure):
                return fail(failure, family: decision.family)
            case let .success(repository):
                switch urlResolver.url(for: decision.request, repository: repository) {
                case let .success(url):
                    Self.logger.info(
                        "Resolved Forge scripting destination family=\(decision.family.rawValue, privacy: .public)"
                    )
                    return url.absoluteString
                case let .failure(error):
                    return fail(error, family: decision.family)
                }
            }
        }
    }

    @MainActor
    private func fail(
        _ failure: ForgeDestinationScriptFailure,
        family: ForgeDestinationScriptFamily? = nil
    ) -> Any? {
        scriptErrorNumber = failure.code
        scriptErrorString = failure.message
        logFailure(code: failure.code, family: family)
        return nil
    }

    @MainActor
    private func fail(_ error: NSError, family: ForgeDestinationScriptFamily) -> Any? {
        scriptErrorNumber = error.code
        scriptErrorString = error.localizedDescription
        logFailure(code: error.code, family: family)
        return nil
    }

    @MainActor
    private func logFailure(code: Int, family: ForgeDestinationScriptFamily?) {
        Self.logger.info(
            "Rejected Forge scripting destination family=\(family?.rawValue ?? "unknown", privacy: .public) code=\(code, privacy: .public)"
        )
    }
}

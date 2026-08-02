import AppKit
import XCTest

@MainActor
final class ForgeScriptingTests: XCTestCase {
    private struct ProviderFixture {
        let remoteURL: String
        let repository: String
        let branch: String
        let commit: String
        let file: String
        let compare: String
        let pullRequest: String
        let issue: String
    }

    private let branchRevisionCode = NSNumber(value: UInt32(0x4672_4272))
    private let tagRevisionCode = NSNumber(value: UInt32(0x4672_5467))
    private let commitRevisionCode = NSNumber(value: UInt32(0x4672_436D))
    private var temporaryDirectories: [URL] = []
    private var documents: [NSDocument] = []

    private func cleanUpFixtures() {
        let documentController = NSDocumentController.shared
        for document in documents {
            documentController.removeDocument(document)
            document.close()
        }
        documents.removeAll()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testScriptingDictionaryDefinesPureContractsForEveryDestinationFamily() throws {
        let expectedArguments: [String: Set<String>] = [
            "forge repository URL": ["document"],
            "forge branch URL": ["branch", "document"],
            "forge commit URL": ["commit", "document"],
            "forge file URL": ["document", "endLine", "path", "revision", "revisionKind", "startLine"],
            "forge compare URL": [
                "baseRevision",
                "baseRevisionKind",
                "document",
                "headRevision",
                "headRevisionKind",
            ],
            "forge pull request URL": ["document", "number"],
            "forge issue URL": ["document", "number"],
        ]
        let descriptions = try commandDescriptions()

        XCTAssertEqual(Set(descriptions.keys).intersection(expectedArguments.keys), Set(expectedArguments.keys))
        for (name, arguments) in expectedArguments {
            let description = try XCTUnwrap(descriptions[name], name)
            XCTAssertEqual(description.commandClassName, "PBForgeDestinationScriptCommand", name)
            XCTAssertEqual(Set(description.argumentNames), arguments, name)
            XCTAssertEqual(description.returnType, "text", name)
            XCTAssertFalse(description.isOptionalArgument(withName: "document"), name)
        }
        let fileDescription = try XCTUnwrap(descriptions["forge file URL"])
        XCTAssertTrue(fileDescription.isOptionalArgument(withName: "startLine"))
        XCTAssertTrue(fileDescription.isOptionalArgument(withName: "endLine"))
        XCTAssertEqual(fileDescription.typeForArgument(withName: "revisionKind"), "forge revision kind")
    }

    func testNSScriptCommandsReturnProviderNativeTextForEveryFamily() throws {
        defer { cleanUpFixtures() }
        let fixtures = [
            ProviderFixture(
                remoteURL: "https://github.com/acme/widgets.git",
                repository: "https://github.com/acme/widgets",
                branch: "https://github.com/acme/widgets/tree/feature%2Fnative",
                commit: "https://github.com/acme/widgets/commit/abc1234",
                file: "https://github.com/acme/widgets/blob/feature%2Fnative/Sources/File.swift#L2-L4",
                compare: "https://github.com/acme/widgets/compare/main...feature%2Fnative",
                pullRequest: "https://github.com/acme/widgets/pull/42",
                issue: "https://github.com/acme/widgets/issues/17"
            ),
            ProviderFixture(
                remoteURL: "https://gitlab.com/acme/widgets.git",
                repository: "https://gitlab.com/acme/widgets",
                branch: "https://gitlab.com/acme/widgets/-/tree/feature%2Fnative",
                commit: "https://gitlab.com/acme/widgets/-/commit/abc1234",
                file: "https://gitlab.com/acme/widgets/-/blob/feature%2Fnative/Sources/File.swift#L2-L4",
                compare: "https://gitlab.com/acme/widgets/-/compare/main...feature%2Fnative",
                pullRequest: "https://gitlab.com/acme/widgets/-/merge_requests/42",
                issue: "https://gitlab.com/acme/widgets/-/issues/17"
            ),
            ProviderFixture(
                remoteURL: "https://bitbucket.org/acme/widgets.git",
                repository: "https://bitbucket.org/acme/widgets",
                branch: "https://bitbucket.org/acme/widgets/src/feature%2Fnative",
                commit: "https://bitbucket.org/acme/widgets/commits/abc1234",
                file: "https://bitbucket.org/acme/widgets/src/feature%2Fnative/Sources/File.swift#lines-2:4",
                compare: "https://bitbucket.org/acme/widgets/branches/compare/feature%2Fnative..main",
                pullRequest: "https://bitbucket.org/acme/widgets/pull-requests/42",
                issue: "https://bitbucket.org/acme/widgets/issues/17"
            ),
        ]

        for fixture in fixtures {
            let document = try openRepositoryDocument(remoteURLs: [fixture.remoteURL])
            let cases: [(String, [String: Any], String)] = [
                ("forge repository URL", [:], fixture.repository),
                ("forge branch URL", ["branch": "feature/native"], fixture.branch),
                ("forge commit URL", ["commit": "abc1234"], fixture.commit),
                (
                    "forge file URL",
                    [
                        "revision": "feature/native",
                        "revisionKind": branchRevisionCode,
                        "path": "Sources/File.swift",
                        "startLine": 2,
                        "endLine": 4,
                    ],
                    fixture.file
                ),
                (
                    "forge compare URL",
                    [
                        "baseRevision": "main",
                        "baseRevisionKind": branchRevisionCode,
                        "headRevision": "feature/native",
                        "headRevisionKind": branchRevisionCode,
                    ],
                    fixture.compare
                ),
                ("forge pull request URL", ["number": 42], fixture.pullRequest),
                ("forge issue URL", ["number": 17], fixture.issue),
            ]

            for (commandName, familyArguments, expectedURL) in cases {
                let command = try scriptCommand(named: commandName)
                command.arguments = familyArguments.merging(["document": document]) { current, _ in current }

                XCTAssertEqual(command.execute() as? String, expectedURL, "\(fixture.remoteURL) \(commandName)")
                XCTAssertEqual(command.scriptErrorNumber, 0, commandName)
                XCTAssertNil(command.scriptErrorString, commandName)
            }
        }
    }

    func testNSScriptCommandsSetStructuredMalformedInputErrorsForEveryFamily() throws {
        defer { cleanUpFixtures() }
        let document = try openRepositoryDocument(remoteURLs: ["https://github.com/acme/widgets.git"])
        let malformed: [(String, [String: Any], Int)] = [
            ("forge repository URL", ["document": NSObject()], 18000),
            ("forge branch URL", ["document": document, "branch": ""], 18003),
            ("forge commit URL", ["document": document], 18003),
            (
                "forge file URL",
                [
                    "document": document,
                    "revision": "main",
                    "revisionKind": branchRevisionCode,
                    "path": "README.md",
                    "endLine": 9,
                ],
                18003
            ),
            (
                "forge compare URL",
                [
                    "document": document,
                    "baseRevision": "main",
                    "baseRevisionKind": branchRevisionCode,
                    "headRevision": "feature",
                ],
                18003
            ),
            ("forge pull request URL", ["document": document, "number": true], 18003),
            ("forge issue URL", ["document": document, "number": 1.5], 18003),
        ]

        for (commandName, arguments, expectedCode) in malformed {
            let command = try scriptCommand(named: commandName)
            command.arguments = arguments

            XCTAssertNil(command.performDefaultImplementation(), commandName)
            XCTAssertEqual(command.scriptErrorNumber, expectedCode, commandName)
            XCTAssertNotNil(command.scriptErrorString, commandName)
        }
    }

    func testNSScriptCommandsParseTagCommitOptionalLinesAndSingleDocumentArrays() throws {
        defer { cleanUpFixtures() }
        let document = try openRepositoryDocument(remoteURLs: ["https://github.com/acme/widgets.git"])
        let commit = String(repeating: "a", count: 40)
        let cases: [(String, [String: Any], String)] = [
            (
                "forge file URL",
                [
                    "document": [document],
                    "revision": "v1.0",
                    "revisionKind": tagRevisionCode,
                    "path": "README.md",
                ],
                "https://github.com/acme/widgets/blob/v1.0/README.md"
            ),
            (
                "forge file URL",
                [
                    "document": document,
                    "revision": commit,
                    "revisionKind": commitRevisionCode,
                    "path": "README.md",
                    "startLine": 7,
                ],
                "https://github.com/acme/widgets/blob/\(commit)/README.md#L7"
            ),
            (
                "forge compare URL",
                [
                    "document": document,
                    "baseRevision": commit,
                    "baseRevisionKind": commitRevisionCode,
                    "headRevision": "v1.0",
                    "headRevisionKind": tagRevisionCode,
                ],
                "https://github.com/acme/widgets/compare/\(commit)...v1.0"
            ),
        ]

        for (commandName, arguments, expectedURL) in cases {
            let command = try scriptCommand(named: commandName)
            command.arguments = arguments

            XCTAssertEqual(command.execute() as? String, expectedURL, commandName)
            XCTAssertEqual(command.scriptErrorNumber, 0, commandName)
            XCTAssertNil(command.scriptErrorString, commandName)
        }
    }

    func testNSScriptCommandsRejectDocumentArraysUnknownEnumsAndNonFiniteNumbers() throws {
        defer { cleanUpFixtures() }
        let document = try openRepositoryDocument(remoteURLs: ["https://github.com/acme/widgets.git"])
        let malformed: [(String, [String: Any], Int)] = [
            ("forge repository URL", ["document": []], 18000),
            ("forge repository URL", ["document": [document, document]], 18000),
            ("forge branch URL", ["document": document, "branch": NSNumber(value: 1)], 18003),
            ("forge issue URL", ["document": document, "number": Double.infinity], 18003),
            (
                "forge file URL",
                [
                    "document": document,
                    "revision": "main",
                    "revisionKind": NSNumber(value: UInt32.max),
                    "path": "README.md",
                ],
                18003
            ),
        ]

        for (commandName, arguments, expectedCode) in malformed {
            let command = try scriptCommand(named: commandName)
            command.arguments = arguments

            XCTAssertNil(command.performDefaultImplementation(), commandName)
            XCTAssertEqual(command.scriptErrorNumber, expectedCode, commandName)
            XCTAssertNotNil(command.scriptErrorString, commandName)
        }
    }

    func testMissingAndAmbiguousBindingsReturnStableErrorsWithoutUIOrPersistence() throws {
        defer { cleanUpFixtures() }
        let unboundDocument = try openRepositoryDocument(remoteURLs: [])
        let ambiguousDocument = try openRepositoryDocument(remoteURLs: [
            "https://github.com/acme/widgets.git",
            "https://gitlab.com/acme/widgets.git",
        ])
        let openWindows = NSApp.windows
        let modalWindow = NSApp.modalWindow
        let sheets = openWindows.flatMap(\.sheets)
        let settingsBefore = UserDefaults.standard.dictionary(forKey: "PBRepositoryUISettings")

        let missing = try scriptCommand(named: "forge repository URL")
        missing.arguments = ["document": unboundDocument]
        XCTAssertNil(missing.execute())
        XCTAssertEqual(missing.scriptErrorNumber, 18001)
        XCTAssertEqual(missing.scriptErrorString, "No Forge Repository can be resolved for this repository.")

        let ambiguous = try scriptCommand(named: "forge repository URL")
        ambiguous.arguments = ["document": ambiguousDocument]
        XCTAssertNil(ambiguous.execute())
        XCTAssertEqual(ambiguous.scriptErrorNumber, 18002)
        XCTAssertEqual(
            ambiguous.scriptErrorString,
            "The repository has multiple possible Forge Repositories; choose a Primary Forge Repository first."
        )

        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: "PBRepositoryUISettings") as NSDictionary?, settingsBefore as NSDictionary?)
        XCTAssertEqual(NSApp.windows, openWindows)
        XCTAssertEqual(NSApp.modalWindow, modalWindow)
        XCTAssertEqual(openWindows.flatMap(\.sheets), sheets)
    }

    private func openRepositoryDocument(remoteURLs: [String]) throws -> NSDocument {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitX-ForgeScripting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        temporaryDirectories.append(repositoryURL)
        try runGit(["init", "--quiet", "--initial-branch=main"], in: repositoryURL)
        for (index, remoteURL) in remoteURLs.enumerated() {
            try runGit(["remote", "add", "remote-\(index)", remoteURL], in: repositoryURL)
        }

        let documentController = NSDocumentController.shared
        let document = try documentController.makeDocument(
            withContentsOf: repositoryURL,
            ofType: "Git Repository"
        )
        documentController.addDocument(document)
        documents.append(document)
        return document
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func commandDescriptions() throws -> [String: NSScriptCommandDescription] {
        try XCTUnwrap(NSScriptSuiteRegistry.shared().commandDescriptions(inSuite: "GitX Suite"))
    }

    private func scriptCommand(named name: String) throws -> PBForgeDestinationScriptCommand {
        let descriptions = try commandDescriptions()
        let description = try XCTUnwrap(descriptions[name])
        return try XCTUnwrap(description.createCommandInstance() as? PBForgeDestinationScriptCommand)
    }
}

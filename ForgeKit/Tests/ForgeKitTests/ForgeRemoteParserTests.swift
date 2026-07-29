@testable import ForgeKit
import XCTest

final class ForgeRemoteParserTests: XCTestCase {
    func testRemoteTableNormalizesSupportedSchemesProvidersUnicodeAndPorts() throws {
        struct Example {
            let remote: String
            let kind: ForgeKind
            let origin: String
            let owner: String
            let name: String
        }
        let examples = [
            Example(
                remote: "git@github.com:acme/widgets.git",
                kind: .github,
                origin: "https://github.com",
                owner: "acme",
                name: "widgets"
            ),
            Example(
                remote: "github.com:acme/widgets",
                kind: .github,
                origin: "https://github.com",
                owner: "acme",
                name: "widgets"
            ),
            Example(
                remote: "ssh://git@gitlab.example/team/subgroup/widgets.git",
                kind: .gitLab,
                origin: "https://gitlab.example",
                owner: "team/subgroup",
                name: "widgets"
            ),
            Example(
                remote: "git://bitbucket.org/acme/widgets.git",
                kind: .bitbucket,
                origin: "https://bitbucket.org",
                owner: "acme",
                name: "widgets"
            ),
            Example(
                remote: "https://github.example:8443/%C3%A9quipe/outils/caf%C3%A9.git",
                kind: .github,
                origin: "https://github.example:8443",
                owner: "équipe/outils",
                name: "café"
            ),
        ]
        for example in examples {
            let parsed = try ForgeRemoteParser.parse(example.remote)
            XCTAssertEqual(parsed.original, example.remote)
            XCTAssertEqual(parsed.repository.forge.kind, example.kind)
            XCTAssertEqual(parsed.repository.forge.origin.url.absoluteString, example.origin)
            XCTAssertEqual(parsed.repository.owner, example.owner)
            XCTAssertEqual(parsed.repository.name, example.name)
            XCTAssertEqual(
                try JSONDecoder().decode(ParsedForgeRemote.self, from: JSONEncoder().encode(parsed)),
                parsed
            )
        }
    }

    func testSSHAndGitTransportPortsDoNotBecomeHTTPSPorts() throws {
        let ssh = try ForgeRemoteParser.parse("ssh://git@example.com:2222/team/repo.git")
        let git = try ForgeRemoteParser.parse("git://example.com:9418/team/repo.git")
        XCTAssertEqual(ssh.repository.forge.origin.url.absoluteString, "https://example.com")
        XCTAssertEqual(git.repository.forge.origin.url.absoluteString, "https://example.com")
    }

    func testRemoteParserRejectsMalformedAndUnsafeInput() throws {
        let cases: [(String, ForgeRemoteParseError)] = [
            ("", .empty),
            ("   ", .empty),
            ("http://github.com/acme/repo.git", .unsupportedScheme("http")),
            ("file:///tmp/repo", .unsupportedScheme("file")),
            ("/tmp/repo", .malformedURL),
            ("../repo", .malformedURL),
            ("github.com:", .malformedURL),
            ("@github.com:acme/repo", .malformedURL),
            ("git@@github.com:acme/repo", .malformedURL),
            ("https://github.com/acme", .missingRepository),
            ("https://github.com/acme/", .malformedPath),
            ("https://github.com/acme//repo", .malformedPath),
            ("https://github.com/acme/repo?token=secret", .queryOrFragmentNotAllowed),
            ("https://github.com/acme/repo#readme", .queryOrFragmentNotAllowed),
            ("https://user@github.com/acme/repo", .credentialsNotAllowed),
            ("ssh://user:password@github.com/acme/repo", .credentialsNotAllowed),
            ("https://github.com/acme/%2E%2E/repo", .unsafePathComponent),
            ("https://github.com/acme%2Frepo/name", .unsafePathComponent),
            ("https://github.com/acme/%ZZ", .unsafePathComponent),
            ("https://github.com:99999/acme/repo", .malformedURL),
            ("git@github.com%00.evil:acme/repo.git", .missingHost),
            ("git@%2egithub.com:acme/repo.git", .missingHost),
        ]
        for (remote, expected) in cases {
            XCTAssertThrowsError(try ForgeRemoteParser.parse(remote), remote) {
                XCTAssertEqual($0 as? ForgeRemoteParseError, expected, remote)
            }
        }
    }

    func testHostDeceptionNeverChangesExactOrigin() throws {
        let suffix = try ForgeRemoteParser.parse("git@github.com.evil.test:acme/repo.git")
        XCTAssertEqual(suffix.repository.forge.origin.host, "github.com.evil.test")
        XCTAssertNotEqual(suffix.repository.forge.origin.host, "github.com")

        let userInfo = "https://github.com@evil.test/acme/repo.git"
        XCTAssertThrowsError(try ForgeRemoteParser.parse(userInfo)) {
            XCTAssertEqual($0 as? ForgeRemoteParseError, .credentialsNotAllowed)
        }

        let similar = try ForgeRemoteParser.parse("git@notgitlab.test:acme/repo.git")
        XCTAssertEqual(similar.repository.forge.kind, .gitLab)
        XCTAssertEqual(similar.repository.forge.origin.host, "notgitlab.test")
    }
}

import Foundation
import XCTest

final class PBTaskDiagnosticRedactorTests: XCTestCase {
    func testOrdinaryURLDoesNotConsumeFollowingColonAndEmailDiagnostics() {
        let input = "fatal: https://github.com/org/repo.git: contact admin@corp.com https://user:secret@other.invalid/repo"
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted(input), "fatal: https://github.com/org/repo.git: contact admin@corp.com https://[redacted]@other.invalid/repo")
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://user.name:123/private-secret@example.invalid/repo"), "https://[redacted]@example.invalid/repo")
    }

    func testManyOrdinaryURLsRequireBoundedSourceReads() throws {
        let data = Data(String(repeating: "https://example.invalid/repo:42 ", count: 300).utf8)
        var readBytes = 0
        let source = PBTaskDiagnosticByteSource(length: Int64(data.count)) { offset, count in
            readBytes += count
            return Data(data[Int(offset) ..< Int(offset) + count])
        }
        var result = Data()
        try PBTaskDiagnosticRedactor.redact(source: source, incomplete: false, bufferSize: 64) { result.append($0) }
        XCTAssertEqual(result, data)
        XCTAssertLessThanOrEqual(readBytes, data.count * 4)
    }

    func testOrdinaryURLBoundariesPreservePortsPathsAndFollowingDiagnostics() {
        for input in [
            "https://example.invalid/repo failed: permission denied",
            "https://example.invalid/repo contact owner@example.invalid",
            "https://example.invalid:443/repo",
            "https://[::1]:443/repo failed: denied",
            "https://example.invalid/a@b?next=c:d",
            "https://example.invalid/repo:42",
            "https://[::1]:443/repo:42",
        ] {
            XCTAssertEqual(PBTaskDiagnosticRedactor.redacted(input), input)
            XCTAssertEqual(PBTaskDiagnostics.redacted(input), input, "Objective-C app boundary")
        }
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://user:secret@example.invalid/repo failed: denied"),
                       "https://[redacted]@example.invalid/repo failed: denied")
    }

    func testNestedSchemeLikeCredentialFragmentsAreEntirelyRedactedAtEveryChunkBoundary() throws {
        let text = "before https://user:prefix/privateScheme://remainingSecret@example.invalid/repo after: diagnostic"
        let input = Data(text.utf8)
        XCTAssertEqual(PBTaskDiagnostics.redacted(text),
                       "before https://[redacted]@example.invalid/repo after: diagnostic")
        for size in 1 ... input.count {
            var result = Data()
            let source = PBTaskDiagnosticByteSource(length: Int64(input.count)) { offset, count in
                Data(input[Int(offset) ..< Int(offset) + count])
            }
            try PBTaskDiagnosticRedactor.redact(source: source, incomplete: false, bufferSize: size) { result.append($0) }
            XCTAssertEqual(String(decoding: result, as: UTF8.self),
                           "before https://[redacted]@example.invalid/repo after: diagnostic", "chunk size \(size)")
        }
    }

    func testCredentialURLsEmbeddedInOrdinaryURLQueriesAreStillRedacted() {
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://[::1]:443/?redirect=https://user:secret@other.invalid/repo"),
                       "https://[::1]:443/?redirect=https://[redacted]@other.invalid/repo")
        let input = "https://example.invalid/?redirect=https://user:secret@other.invalid/repo"
        let expected = "https://example.invalid/?redirect=https://[redacted]@other.invalid/repo"
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted(input), expected)
        XCTAssertEqual(PBTaskDiagnostics.redacted(input), expected)
    }

    func testConservativeRedactionHandlesMalformedAndCombinedUserinfo() {
        for secret in ["secret/with/slashes", "secret?with=query", "secret#fragment", "secret with spaces", "密碼/更多", "secret@early/remaining-secret"] {
            XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://user:\(secret)@example.invalid/repo"),
                           "https://[redacted]@example.invalid/repo")
        }
    }

    func testNumericAndSeparatorPrefixedMalformedUserinfoIsRedacted() throws {
        for input in [
            "https://user:123/fake-secret@example.invalid/repo",
            "https://user:123 fake-secret@example.invalid/repo",
            "https://user/name:fake-secret@example.invalid/repo",
            "https://user?name:fake-secret@example.invalid/repo",
            "https://user#name:fake-secret@example.invalid/repo",
            "https://user name:fake-secret@example.invalid/repo",
            "https://user:123/https://fake-secret@example.invalid/repo",
        ] {
            let bytes = Data(input.utf8)
            for size in 1 ... bytes.count {
                let source = PBTaskDiagnosticByteSource(length: Int64(bytes.count)) { offset, count in
                    Data(bytes[Int(offset) ..< Int(offset) + count])
                }
                var output = Data()
                try PBTaskDiagnosticRedactor.redact(source: source, incomplete: false, bufferSize: size) { output.append($0) }
                XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("fake-secret"), "\(input), chunk size \(size)")
            }
        }
    }

    func testSchemeAndCredentialSpanningEveryChunkBoundaryAreRedacted() throws {
        let input = Data("before https://user:密碼/with@early/path@example.invalid/repo\nafter".utf8)
        for size in 1 ... input.count {
            var rendered = Data()
            let source = PBTaskDiagnosticByteSource(length: Int64(input.count)) { offset, count in
                let start = Int(offset)
                return Data(input[start ..< start + count])
            }
            try PBTaskDiagnosticRedactor.redact(source: source, incomplete: false, bufferSize: size) { rendered.append($0) }
            XCTAssertEqual(String(decoding: rendered, as: UTF8.self), "before https://[redacted]@example.invalid/repo\nafter")
        }
    }

    func testLongMalformedCredentialUsesBoundedReadsAndPreservesSurroundingOutput() throws {
        let secret = String(repeating: "密碼/?# secret@early/", count: 20000)
        let input = Data(("header\nhttps://user:" + secret + "@example.invalid/repo\nfinal").utf8)
        var maximumRead = 0
        var result = Data()
        let source = PBTaskDiagnosticByteSource(length: Int64(input.count)) { offset, count in
            maximumRead = max(maximumRead, count)
            return Data(input[Int(offset) ..< Int(offset) + count])
        }
        try PBTaskDiagnosticRedactor.redact(source: source, incomplete: false) { result.append($0) }
        XCTAssertLessThanOrEqual(maximumRead, 64 * 1024)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "header\nhttps://[redacted]@example.invalid/repo\nfinal")
    }

    func testIncompleteAuthorityIsMaskedBeforeItsSeparatorArrives() throws {
        for input in ["https://user:123/unfinished-secret", "https://user/name:unfinished-secret"] {
            XCTAssertFalse(PBTaskDiagnosticRedactor.redacted(input, incomplete: true).contains("unfinished-secret"))
        }
        let input = Data("message\nhttps://user:secret/unfinished".utf8)
        let source = PBTaskDiagnosticByteSource(length: Int64(input.count)) { offset, count in
            Data(input[Int(offset) ..< Int(offset) + count])
        }
        var output = Data()
        try PBTaskDiagnosticRedactor.redact(source: source, incomplete: true) { output.append($0) }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "message\nhttps://[redacted incomplete authority]")
    }

    func testNestedSchemeInsideUnresolvedMalformedUserinfoDoesNotExposeEitherSecret() {
        let output = PBTaskDiagnosticRedactor.redacted("https://user:secret/https://othersecret@example.invalid/repo")
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("othersecret"))
        XCTAssertTrue(output.contains("https://[redacted]@example.invalid/repo"))
    }

    func testIncompleteAuthorityMasksSuffixAfterAnAmbiguousEarlierAtSign() throws {
        let input = Data("https://user:secret@early/remaining-secret".utf8)
        let source = PBTaskDiagnosticByteSource(length: Int64(input.count)) { offset, count in
            Data(input[Int(offset) ..< Int(offset) + count])
        }
        var output = Data()
        try PBTaskDiagnosticRedactor.redact(source: source, incomplete: true) { output.append($0) }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "https://[redacted incomplete authority]")
    }

    func testCompleteUnresolvedColonAuthorityIsMaskedAtEOFAndNewline() {
        for input in ["https://user:secret", "https://user:secret/unfinished", "https://user:secret\nnext-line"] {
            let output = PBTaskDiagnosticRedactor.redacted(input)
            XCTAssertFalse(output.contains("secret"), input)
            XCTAssertTrue(output.contains("[redacted"), input)
        }
        XCTAssertTrue(PBTaskDiagnosticRedactor.redacted("https://user:secret\nnext-line").contains("next-line"))
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://example.invalid/repo\nnext-line"), "https://example.invalid/repo\nnext-line")
    }

    func testMultipleURIsAndOrdinaryTextStayIndependent() {
        let ambiguous = "https://user:123 fake-secret@localhost/path https://next:password@two.invalid/repo"
        let safe = "https://[redacted]@localhost/path https://[redacted]@two.invalid/repo"
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted(ambiguous), safe)
        XCTAssertEqual(PBTaskDiagnostics.redacted(ambiguous), safe)
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://user/name:secret@one.invalid/repo contact owner@example.invalid"),
                       "https://[redacted]@one.invalid/repo contact owner@example.invalid")
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://user/name:secret@one.invalid/path failed: denied https://next:password@two.invalid/repo"),
                       "https://[redacted]@one.invalid/path failed: denied https://[redacted]@two.invalid/repo")
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("https://one.invalid https://user:password@two.invalid/path\nmail@example.invalid -1://entry@example.invalid"),
                       "https://one.invalid https://[redacted]@two.invalid/path\nmail@example.invalid -1://entry@example.invalid")
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted("123+.-abc://user:password@example.invalid/repo"),
                       "123+.-abc://[redacted]@example.invalid/repo")
        XCTAssertEqual(PBTaskDiagnosticRedactor.redacted(""), "")
    }

    func testReadAndSinkFailuresPropagateInsteadOfPublishingUnsafeFragments() {
        let failure = NSError(domain: "RedactorFixture", code: 1)
        let missing = PBTaskDiagnosticByteSource(length: 4) { _, _ in Data() }
        XCTAssertThrowsError(try PBTaskDiagnosticRedactor.redact(source: missing, incomplete: false) { _ in })
        let unreadable = PBTaskDiagnosticByteSource(length: 4) { _, _ in throw failure }
        XCTAssertThrowsError(try PBTaskDiagnosticRedactor.redact(source: unreadable, incomplete: false) { _ in })
        let bytes = Data("safe".utf8)
        let readable = PBTaskDiagnosticByteSource(length: 4) { offset, count in Data(bytes[Int(offset) ..< Int(offset) + count]) }
        XCTAssertThrowsError(try PBTaskDiagnosticRedactor.redact(source: readable, incomplete: false) { _ in throw failure })
    }

    func testUTF8RendererPreservesScalarsAcrossEveryInputChunkBoundary() throws {
        let input = Data("ascii é 密碼 🙂\n".utf8)
        for boundary in 0 ... input.count {
            var renderer = PBTaskDiagnosticUTF8Renderer()
            var result = Data()
            try renderer.append(Data(input.prefix(boundary))) { result.append($0) }
            try renderer.append(Data(input.dropFirst(boundary))) { result.append($0) }
            try renderer.finish { result.append($0) }
            XCTAssertEqual(result, input)
        }
    }

    func testUTF8RendererEscapesInvalidSequencesIncompleteScalarsAndControls() throws {
        let input = Data([0, 1, 27, 127, 255, 192, 175, 224, 128, 128, 237, 160, 128, 244, 144, 128, 128, 194])
        var renderer = PBTaskDiagnosticUTF8Renderer()
        var result = Data()
        for byte in input {
            try renderer.append(Data([byte])) { result.append($0) }
        }
        try renderer.finish { result.append($0) }
        XCTAssertEqual(String(data: result, encoding: .utf8), "\\x00\\x01\\x1B\\x7F\\xFF\\xC0\\xAF\\xE0\\x80\\x80\\xED\\xA0\\x80\\xF4\\x90\\x80\\x80\\xC2")
    }

    func testUTF8RendererFlushesBoundedValidChunksAndPropagatesSinkFailure() throws {
        let input = Data((String(repeating: "🙂", count: 20000) + "\t\r\n").utf8)
        var renderer = PBTaskDiagnosticUTF8Renderer()
        var chunks: [Data] = []
        try renderer.append(input) { chunks.append($0) }
        try renderer.finish { chunks.append($0) }
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, input)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 64 * 1024 + 3 && String(data: $0, encoding: .utf8) != nil })
        let failure = NSError(domain: "RendererFixture", code: 1)
        XCTAssertThrowsError(try renderer.append(Data("safe".utf8)) { _ in throw failure })
        var incomplete = PBTaskDiagnosticUTF8Renderer()
        try incomplete.append(Data([194])) { _ in XCTFail("An unfinished scalar stays pending") }
        XCTAssertThrowsError(try incomplete.finish { _ in throw failure })
    }
}

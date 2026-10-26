import XCTest

final class GitBinaryTests: XCTestCase {
    func testEmbeddedToolVersionRemainsLocalAndHasItsEstablishedOutputContract() throws {
        let tool = try XCTUnwrap(Bundle.main.url(forResource: "gitx", withExtension: nil))
        let result = try toolVersion(tool)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.hasPrefix("Half Dark version "))
        XCTAssertTrue(result.output.hasSuffix("\n"))
    }

    func testToolVersionThroughASymlinkMatchesDirectInvocation() throws {
        let tool = try XCTUnwrap(Bundle.main.url(forResource: "gitx", withExtension: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("gitx with spaces")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        let direct = try toolVersion(tool)
        let linked = try toolVersion(link)
        XCTAssertEqual(linked.output, direct.output)
        XCTAssertEqual(linked.status, direct.status)
    }

    private func toolVersion(_ tool: URL) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    func testDiscoveryVersionAndFallbackErrorRemainAvailable() {
        XCTAssertFalse(PBGitBinary.searchLocations().isEmpty)
        XCTAssertNotNil(PBGitBinary.version())
        XCTAssertFalse(PBGitBinary.notFoundError().isEmpty)
    }
}

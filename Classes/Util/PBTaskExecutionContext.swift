import Foundation

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// Immutable validated configuration. PBTask owns argument/environment validation
/// and catches Objective-C exceptions before this value reaches Swift pipe I/O.
@objc(PBTaskExecutionContext)
final nonisolated class PBTaskExecutionContext: NSObject, Sendable {
    @objc let launchPath: String
    @objc let arguments: [String]
    @objc let environment: [String: String]
    @objc let workingDirectory: String?

    @objc(initWithLaunchPath:arguments:environment:workingDirectory:)
    init(launchPath: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
        self.launchPath = launchPath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        super.init()
    }

    func configuration(stdin: Int32, stdout: Int32, stderr: Int32) -> PBChildProcessConfiguration {
        PBChildProcessConfiguration(launchPath: launchPath, arguments: arguments, environment: environment,
                                    workingDirectory: workingDirectory, standardInputFileDescriptor: stdin,
                                    standardOutputFileDescriptor: stdout, standardErrorFileDescriptor: stderr)
    }
}

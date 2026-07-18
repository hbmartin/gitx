import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C repository wiring calls this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryIgnoreFileService)
final nonisolated class RepositoryIgnoreFileService: NSObject {
    private let fileURL: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryIgnoreFileService")

    @objc(initWithFileURL:)
    convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, fileManager: .default)
    }

    init(fileURL: URL, fileManager: FileManager) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        super.init()
    }

    @objc(appendPaths:error:)
    func append(
        paths: [String],
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        do {
            let fileExists = fileManager.fileExists(atPath: fileURL.path)
            var encoding = String.Encoding.utf8
            let existingContents: String
            if fileExists {
                let data = try Data(contentsOf: fileURL)
                if data.isEmpty {
                    existingContents = ""
                } else {
                    existingContents = try String(contentsOf: fileURL, usedEncoding: &encoding)
                }
            } else {
                existingContents = ""
            }

            guard !paths.isEmpty else {
                if !fileExists {
                    try Data().write(to: fileURL, options: .atomic)
                }
                logger.debug("Ignored empty path append request")
                return true
            }

            let newline = Self.newlineConvention(in: existingContents)
            let appendedContents = paths.joined(separator: newline)
            let separator = Self.needsSeparator(after: existingContents) ? newline : ""
            try (existingContents + separator + appendedContents).write(
                to: fileURL,
                atomically: true,
                encoding: encoding
            )
            let filename = fileURL.lastPathComponent
            logger.info("Appended \(paths.count) path(s) to \(filename)")
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Failed to append ignore paths: \(error.localizedDescription)")
            return false
        }
    }

    private static func newlineConvention(in contents: String) -> String {
        if contents.contains("\r\n") {
            return "\r\n"
        }
        if contents.contains("\n") {
            return "\n"
        }
        if contents.contains("\r") {
            return "\r"
        }
        return "\n"
    }

    private static func needsSeparator(after contents: String) -> Bool {
        guard let finalCharacter = contents.last else { return false }
        return finalCharacter != "\n" && finalCharacter != "\r"
    }
}

// swiftlint:enable unused_declaration

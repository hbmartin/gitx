import Foundation
import OSLog // swiftlint:disable:this unused_import

// Objective-C repository wiring calls this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryIgnoreFileService)
final nonisolated class RepositoryIgnoreFileService: NSObject {
    private static let transactionLock = NSLock()
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
            try coordinateAppend(paths)
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Failed to append ignore paths: \(error.localizedDescription)")
            return false
        }
    }

    private func coordinateAppend(_ paths: [String]) throws {
        Self.transactionLock.lock()
        defer { Self.transactionLock.unlock() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessorError: Error?
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try append(paths, to: coordinatedURL)
            } catch {
                accessorError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let accessorError {
            throw accessorError
        }
    }

    private func append(_ paths: [String], to coordinatedURL: URL) throws {
        let fileExists = fileManager.fileExists(atPath: coordinatedURL.path)
        var encoding = String.Encoding.utf8
        let existingContents: String
        if fileExists {
            let data = try Data(contentsOf: coordinatedURL)
            if data.isEmpty {
                existingContents = ""
            } else {
                do {
                    existingContents = try String(contentsOf: coordinatedURL, usedEncoding: &encoding)
                } catch {
                    encoding = .utf8
                    existingContents = try String(contentsOf: coordinatedURL, encoding: .utf8)
                }
            }
        } else {
            existingContents = ""
        }

        guard !paths.isEmpty else {
            if !fileExists {
                try Data().write(to: coordinatedURL, options: .atomic)
            }
            logger.debug("Ignored empty path append request")
            return
        }

        let newline = Self.newlineConvention(in: existingContents)
        let appendedContents = paths.joined(separator: newline)
        let separator = Self.needsSeparator(after: existingContents) ? newline : ""
        try (existingContents + separator + appendedContents).write(
            to: coordinatedURL,
            atomically: true,
            encoding: encoding
        )
        logger.info("Appended \(paths.count) path(s) to \(coordinatedURL.lastPathComponent)")
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

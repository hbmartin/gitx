import Foundation

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// Decodes streamed UTF-8 without replacing a scalar merely because its bytes
/// were divided across process-output reads.
// swift6-safety-justification: `lock` protects every read and mutation of the pending byte buffer.
@objc(PBIncrementalUTF8Decoder)
final nonisolated class IncrementalUTF8Decoder: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingBytes = Data()

    @objc(appendData:)
    func append(_ data: Data) -> String {
        lock.lock()
        defer { lock.unlock() }

        pendingBytes.append(data)
        let completeLength = Self.completePrefixLength(in: pendingBytes)
        guard completeLength > 0 else { return "" }

        let sourceData = pendingBytes
        let completeData = Data(sourceData.prefix(completeLength))
        pendingBytes = Data(sourceData.dropFirst(completeLength))
        return String(decoding: completeData, as: UTF8.self)
    }

    @objc
    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }

        let finalData = pendingBytes
        pendingBytes = Data()
        return String(decoding: finalData, as: UTF8.self)
    }

    private static func completePrefixLength(in data: Data) -> Int {
        let bytes = Array(data)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            let expectedLength: Int
            switch byte {
            case 0x00 ... 0x7F:
                expectedLength = 1
            case 0xC2 ... 0xDF:
                expectedLength = 2
            case 0xE0 ... 0xEF:
                expectedLength = 3
            case 0xF0 ... 0xF4:
                expectedLength = 4
            default:
                expectedLength = 1
            }

            guard expectedLength > 1 else {
                index += 1
                continue
            }

            let availableContinuationCount = min(expectedLength - 1, bytes.count - index - 1)
            let continuationBytesAreValid = (0 ..< availableContinuationCount).allSatisfy {
                bytes[index + $0 + 1] & 0xC0 == 0x80
            }
            if !continuationBytesAreValid {
                index += 1
                continue
            }
            if availableContinuationCount < expectedLength - 1 {
                return index
            }
            index += expectedLength
        }

        return index
    }
}

// swiftlint:enable unused_declaration

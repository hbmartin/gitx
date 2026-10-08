import Foundation

/// A seekable source keeps arbitrarily long URL authorities out of memory.
nonisolated struct PBTaskDiagnosticByteSource {
    let length: Int64
    let read: (Int64, Int) throws -> Data
}

nonisolated enum PBTaskDiagnosticRedactor {
    static let bufferSize = 64 * 1024

    static func redacted(_ text: String, incomplete: Bool = false) -> String {
        let data = Data(text.utf8)
        var result = Data()
        let source = PBTaskDiagnosticByteSource(length: Int64(data.count)) { offset, count in
            Data(data[Int(offset) ..< Int(offset) + count])
        }
        // The in-memory source and sink cannot fail.
        try? redact(source: source, incomplete: incomplete) { result.append($0) }
        return String(decoding: result, as: UTF8.self)
    }

    static func redact(
        source: PBTaskDiagnosticByteSource,
        incomplete: Bool,
        bufferSize: Int = PBTaskDiagnosticRedactor.bufferSize,
        output: (Data) throws -> Void
    ) throws {
        let chunkSize = min(Self.bufferSize, max(1, bufferSize))
        let cursor = Cursor(source: source, bufferSize: chunkSize)
        var offset: Int64 = 0
        var copiedThrough: Int64 = 0
        var tokenHasLetter = false
        func copy(until end: Int64) throws {
            while copiedThrough < end {
                let count = Int(min(Int64(chunkSize), end - copiedThrough))
                let data = try source.read(copiedThrough, count)
                guard data.count == count else { throw readError() }
                try output(data)
                copiedThrough += Int64(count)
            }
        }

        while offset < source.length {
            let byte = try cursor.byte(at: offset)
            if byte == 58, tokenHasLetter,
               offset + 2 < source.length,
               try cursor.byte(at: offset + 1) == 47,
               try cursor.byte(at: offset + 2) == 47
            {
                let start = offset + 3
                let span = try authoritySpan(start: start, cursor: cursor, length: source.length)
                let stopped = incomplete && span.end == source.length
                if start < span.end, stopped || (span.lastAt == nil && span.ambiguous) {
                    try copy(until: start)
                    try output(Data((stopped ? "[redacted incomplete authority]" : "[redacted ambiguous authority]").utf8))
                    copiedThrough = span.end
                } else if let lastAt = span.lastAt {
                    try copy(until: start)
                    try output(Data("[redacted]@".utf8))
                    copiedThrough = lastAt + 1
                }
                offset = span.end
                tokenHasLetter = false
                continue
            }
            if isSchemeByte(byte) {
                tokenHasLetter = tokenHasLetter || isLetter(byte)
            } else {
                tokenHasLetter = false
            }
            offset += 1
        }
        try copy(until: source.length)
    }

    private struct AuthoritySpan {
        let end: Int64
        let lastAt: Int64?
        let ambiguous: Bool
    }

    /// Only authority bytes decide whether this is userinfo. Once credentials
    /// are suspected, malformed separators and nested schemes remain inside the
    /// redacted span; they never become a new, independently copied URL.
    private static func authoritySpan(start: Int64, cursor: Cursor, length: Int64) throws -> AuthoritySpan {
        var end = start
        var colon: Int64?
        var lastAt: Int64?
        var bracketed = false
        while end < length {
            let byte = try cursor.byte(at: end)
            if byte <= 32 || byte == 47 || byte == 63 || byte == 35 {
                break
            }
            if byte == 91 {
                bracketed = true
            }
            if byte == 93 {
                bracketed = false
            }
            if byte == 58, !bracketed, colon == nil {
                colon = end
            }
            if byte == 64 {
                lastAt = end
            }
            end += 1
        }
        var numericPort = false
        if let colon, lastAt == nil, colon + 1 < end {
            numericPort = true
            var position = colon + 1
            while position < end {
                let byte = try cursor.byte(at: position)
                if !(48 ... 57).contains(byte) {
                    numericPort = false
                }
                position += 1
            }
        }
        let ambiguous = colon != nil && !numericPort
        let credentials = ambiguous || lastAt != nil
        if !credentials {
            // Continue scanning ordinary paths and queries for independent URLs.
            return AuthoritySpan(end: end, lastAt: nil, ambiguous: false)
        }
        var malformedUserinfo = false
        // A normal URL ends at whitespace. Malformed userinfo can contain spaces
        // before its @, but ordinary text following the host stays independent.
        while end < length {
            let byte = try cursor.byte(at: end)
            if byte == 10 || byte == 13 || (byte <= 32 && (!credentials || (lastAt != nil && !malformedUserinfo))) {
                break
            }
            if credentials, lastAt == nil, byte <= 32 || byte == 47 || byte == 63 || byte == 35 {
                malformedUserinfo = true
            }
            if credentials, byte == 64 {
                lastAt = end
            }
            end += 1
        }
        return AuthoritySpan(end: end, lastAt: lastAt, ambiguous: ambiguous)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func isSchemeByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (48 ... 57).contains(byte) || byte == 43 || byte == 45 || byte == 46
    }

    private static func readError() -> NSError {
        NSError(domain: "PBTaskDiagnosticCaptureError", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Push output could not be read safely."])
    }

    private final nonisolated class Cursor {
        let source: PBTaskDiagnosticByteSource
        let bufferSize: Int
        var start: Int64 = -1
        var bytes: [UInt8] = []

        init(source: PBTaskDiagnosticByteSource, bufferSize: Int) {
            self.source = source
            self.bufferSize = bufferSize
        }

        func byte(at offset: Int64) throws -> UInt8 {
            if offset < start || offset >= start + Int64(bytes.count) {
                let count = Int(min(Int64(bufferSize), source.length - offset))
                let data = try source.read(offset, count)
                guard data.count == count else { throw readError() }
                bytes = Array(data)
                start = offset
            }
            return bytes[Int(offset - start)]
        }
    }
}

/// Renders every captured byte without letting invalid UTF-8 disappear in replacement characters.
nonisolated struct PBTaskDiagnosticUTF8Renderer {
    private static let hexDigits = Array("0123456789ABCDEF".utf8)
    private var pending: [UInt8] = []

    mutating func append(_ data: Data, output: (Data) throws -> Void) throws {
        try render(pending + Array(data), finishing: false, output: output)
    }

    mutating func finish(output: (Data) throws -> Void) throws {
        try render(pending, finishing: true, output: output)
    }

    private mutating func render(_ bytes: [UInt8], finishing: Bool, output: (Data) throws -> Void) throws {
        pending = []
        var rendered = Data()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let length: Int
            switch byte {
            case 0 ... 127: length = 1
            case 194 ... 223: length = 2
            case 224 ... 239: length = 3
            case 240 ... 244: length = 4
            default: length = 0
            }
            let available = min(length, bytes.count - index)
            var valid = length > 0
            if length > 1, available > 1 {
                for position in 1 ..< available {
                    let continuation = bytes[index + position]
                    let lower: UInt8 = position == 1 && byte == 224 ? 160 : position == 1 && byte == 240 ? 144 : 128
                    let upper: UInt8 = position == 1 && byte == 237 ? 159 : position == 1 && byte == 244 ? 143 : 191
                    if continuation < lower || continuation > upper {
                        valid = false
                    }
                }
            }
            if valid, available < length, !finishing {
                pending = Array(bytes[index...])
                break
            }
            let isControl = byte < 32 && byte != 9 && byte != 10 && byte != 13 || byte == 127
            if valid, available == length, !isControl {
                rendered.append(contentsOf: bytes[index ..< index + length])
                index += length
            } else {
                rendered.append(contentsOf: [92, 120, Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 15)]])
                index += 1
            }
            if rendered.count >= 64 * 1024 {
                try output(rendered)
                rendered.removeAll(keepingCapacity: true)
            }
        }
        if !rendered.isEmpty {
            try output(rendered)
        }
    }
}

import Foundation

/// A seekable source keeps arbitrarily long URL authorities out of memory.
nonisolated struct PBTaskDiagnosticByteSource {
    let length: Int64
    let read: (Int64, Int) throws -> Data
}

nonisolated enum PBTaskDiagnosticRedactor {
    static let bufferSize = 64 * 1024

    static func redacted(_ text: String) -> String {
        let data = Data(text.utf8)
        var result = Data()
        let source = PBTaskDiagnosticByteSource(length: Int64(data.count)) { offset, count in
            Data(data[Int(offset) ..< Int(offset) + count])
        }
        // The in-memory source and sink cannot fail.
        try? redact(source: source, incomplete: false) { result.append($0) }
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
        var tokenStart: Int64 = 0
        var tokenHasLetter = false
        var authorityStart: Int64?
        var authorityHasColon = false
        var lastAt: Int64?

        func copy(until end: Int64) throws {
            while copiedThrough < end {
                let count = Int(min(Int64(chunkSize), end - copiedThrough))
                let data = try source.read(copiedThrough, count)
                guard data.count == count else { throw readError() }
                try output(data)
                copiedThrough += Int64(count)
            }
        }

        func finishAuthority(at end: Int64, stopped: Bool = false) throws {
            guard let start = authorityStart else { return }
            if stopped || (lastAt == nil && authorityHasColon), start < end {
                // Neither a capture cutoff nor a complete malformed authority
                // establishes where its userinfo would have ended.
                try copy(until: start)
                let replacement = stopped ? "[redacted incomplete authority]" : "[redacted ambiguous authority]"
                try output(Data(replacement.utf8))
                copiedThrough = end
            } else if let lastAt {
                try copy(until: start)
                try output(Data("[redacted]@".utf8))
                copiedThrough = lastAt + 1
            }
        }

        while offset < source.length {
            let byte = try cursor.byte(at: offset)
            if authorityStart != nil, byte == 10 || byte == 13 {
                try finishAuthority(at: offset)
                authorityStart = nil
                authorityHasColon = false
                lastAt = nil
            }
            if byte == 58, tokenHasLetter,
               offset + 2 < source.length,
               try cursor.byte(at: offset + 1) == 47,
               try cursor.byte(at: offset + 2) == 47
            {
                // A later URL is a boundary even when malformed userinfo contains spaces.
                // A URL-looking substring can itself be part of malformed userinfo.
                // Preserve ordinary independent URLs while hiding an ambiguous prefix.
                try finishAuthority(at: tokenStart, stopped: authorityHasColon)
                offset += 3
                authorityStart = offset
                authorityHasColon = false
                lastAt = nil
                tokenStart = offset
                tokenHasLetter = false
                continue
            }
            if authorityStart != nil, byte == 64 {
                lastAt = offset
            }
            if authorityStart != nil, byte == 58 {
                authorityHasColon = true
            }
            if isSchemeByte(byte) {
                tokenHasLetter = tokenHasLetter || isLetter(byte)
            } else {
                tokenStart = offset + 1
                tokenHasLetter = false
            }
            offset += 1
        }
        try finishAuthority(at: source.length, stopped: incomplete)
        try copy(until: source.length)
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

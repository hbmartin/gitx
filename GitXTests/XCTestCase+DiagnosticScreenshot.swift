import AppKit
import XCTest

extension XCTestCase {
    @MainActor
    func attachScreenshot(
        of view: NSView,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try add(diagnosticScreenshotAttachment(of: view, named: name, file: file, line: line))
    }

    @MainActor
    func attachScreenshot(
        of view: NSView?,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let view else {
            XCTFail("Diagnostic screenshot view is unavailable", file: file, line: line)
            return
        }
        do {
            try add(diagnosticScreenshotAttachment(of: view, named: name, file: file, line: line))
        } catch {}
    }

    @MainActor
    func attachScreenshot(
        of window: NSWindow,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let contentView = try XCTUnwrap(
            window.contentView,
            "Diagnostic screenshot window content is unavailable",
            file: file,
            line: line
        )
        try add(diagnosticScreenshotAttachment(of: contentView, named: name, file: file, line: line))
    }

    @MainActor
    private func diagnosticScreenshotAttachment(
        of view: NSView,
        named name: String,
        file: StaticString,
        line: UInt
    ) throws -> XCTAttachment {
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "Diagnostic screenshot could not allocate a bitmap",
            file: file,
            line: line
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

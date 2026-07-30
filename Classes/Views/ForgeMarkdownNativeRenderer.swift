import AppKit
import ForgeKit
import OSLog

@MainActor
protocol ForgeMarkdownNavigationRouting: AnyObject {
    func activateMarkdownLink(_ target: ForgeMarkdownLinkTarget)
    func openMarkdownLinkInBrowser(_ url: URL)
}

struct ForgeMarkdownRenderedDocument {
    let attributedString: NSAttributedString
    let headingRanges: [ForgeMarkdownHeadingID: NSRange]
    let linkTargets: [URL: ForgeMarkdownLinkTarget]
}

@MainActor
struct ForgeMarkdownNativeRenderer {
    private enum Metric {
        static let bodySize: CGFloat = 13
        static let codeSize: CGFloat = 12
    }

    private let bodyFont = NSFont.systemFont(ofSize: Metric.bodySize)
    private let codeFont = NSFont.monospacedSystemFont(ofSize: Metric.codeSize, weight: .regular)

    func render(_ document: ForgeMarkdownDocument) -> ForgeMarkdownRenderedDocument {
        let output = NSMutableAttributedString()
        var headings: [ForgeMarkdownHeadingID: NSRange] = [:]
        var links: [URL: ForgeMarkdownLinkTarget] = [:]
        appendBlocks(document.blocks, to: output, headings: &headings, links: &links, depth: 0)
        return ForgeMarkdownRenderedDocument(
            attributedString: output,
            headingRanges: headings,
            linkTargets: links
        )
    }

    private func appendBlocks(
        _ blocks: [ForgeMarkdownBlock],
        to output: NSMutableAttributedString,
        headings: inout [ForgeMarkdownHeadingID: NSRange],
        links: inout [URL: ForgeMarkdownLinkTarget],
        depth: Int
    ) {
        for (index, block) in blocks.enumerated() {
            if index > 0, output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            appendBlock(block, to: output, headings: &headings, links: &links, depth: depth)
        }
    }

    private func appendBlock(
        _ block: ForgeMarkdownBlock,
        to output: NSMutableAttributedString,
        headings: inout [ForgeMarkdownHeadingID: NSRange],
        links: inout [URL: ForgeMarkdownLinkTarget],
        depth: Int
    ) {
        switch block {
        case let .paragraph(inlines):
            appendInlines(inlines, to: output, attributes: bodyAttributes(), links: &links)
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        case let .heading(level, identifier, content):
            let start = output.length
            let attributes = headingAttributes(level: level)
            appendInlines(content, to: output, attributes: attributes, links: &links)
            let length = output.length - start
            if length > 0 {
                headings[identifier] = NSRange(location: start, length: length)
                output.addAttribute(
                    .forgeMarkdownHeading,
                    value: identifier.rawValue,
                    range: NSRange(location: start, length: length)
                )
            }
            output.append(NSAttributedString(string: "\n", attributes: attributes))
        case let .blockQuote(blocks):
            output.append(NSAttributedString(
                string: "│ ",
                attributes: bodyAttributes(foregroundColor: .tertiaryLabelColor)
            ))
            appendBlocks(blocks, to: output, headings: &headings, links: &links, depth: depth + 1)
        case let .unorderedList(items):
            appendList(items, start: nil, to: output, headings: &headings, links: &links, depth: depth)
        case let .orderedList(start, items):
            appendList(items, start: start, to: output, headings: &headings, links: &links, depth: depth)
        case let .table(table):
            appendTable(table, to: output, links: &links)
        case .thematicBreak:
            output.append(NSAttributedString(
                string: "────────────────────────────────────────\n",
                attributes: bodyAttributes(foregroundColor: .separatorColor)
            ))
        case let .codeBlock(language, code):
            if let language {
                output.append(NSAttributedString(
                    string: language.uppercased() + "\n",
                    attributes: bodyAttributes(
                        font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                        foregroundColor: .secondaryLabelColor
                    )
                ))
            }
            let value = code.hasSuffix("\n") ? code : code + "\n"
            output.append(NSAttributedString(
                string: value,
                attributes: bodyAttributes(
                    font: codeFont,
                    backgroundColor: .controlBackgroundColor
                )
            ))
        }
    }

    private func appendList(
        _ items: [ForgeMarkdownListItem],
        start: UInt?,
        to output: NSMutableAttributedString,
        headings: inout [ForgeMarkdownHeadingID: NSRange],
        links: inout [URL: ForgeMarkdownLinkTarget],
        depth: Int
    ) {
        for (offset, item) in items.enumerated() {
            let marker: String
            if let taskState = item.taskState {
                marker = taskState == .checked ? "☑︎" : "☐︎"
            } else if let start {
                let (number, overflow) = start.addingReportingOverflow(UInt(offset))
                marker = "\(overflow ? UInt.max : number)."
            } else {
                marker = "•"
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = CGFloat(depth) * 14
            paragraph.headIndent = CGFloat(depth) * 14 + 22
            paragraph.paragraphSpacing = 3
            output.append(NSAttributedString(
                string: "\(String(repeating: "  ", count: depth))\(marker) ",
                attributes: bodyAttributes(paragraphStyle: paragraph)
            ))
            appendBlocks(
                item.blocks,
                to: output,
                headings: &headings,
                links: &links,
                depth: depth + 1
            )
        }
    }

    private func appendTable(
        _ table: ForgeMarkdownTable,
        to output: NSMutableAttributedString,
        links: inout [URL: ForgeMarkdownLinkTarget]
    ) {
        let rowCount = table.rows.count + 1
        let columnCount = max(
            table.columnAlignments.count,
            ([table.header.count] + table.rows.map(\.count)).max() ?? 0
        )
        guard rowCount > 0, columnCount > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = (0 ..< columnCount).map { columnIndex in
            let alignment = columnIndex < table.columnAlignments.count
                ? table.columnAlignments[columnIndex]
                : nil
            let textAlignment = textAlignment(for: alignment)
            let columnOrigin = CGFloat(columnIndex) * 150
            let location = switch textAlignment {
            case .center: columnOrigin + 75
            case .right: columnOrigin + 146
            default: columnOrigin + 4
            }
            return NSTextTab(
                textAlignment: textAlignment,
                location: location
            )
        }
        paragraph.defaultTabInterval = 150
        let rows = [table.header] + table.rows
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0 ..< columnCount {
                output.append(NSAttributedString(
                    string: "\t",
                    attributes: bodyAttributes(paragraphStyle: paragraph)
                ))
                guard columnIndex < row.count else { continue }
                let font = rowIndex == 0
                    ? NSFont.systemFont(ofSize: Metric.bodySize, weight: .semibold)
                    : bodyFont
                appendInlines(
                    row[columnIndex].content,
                    to: output,
                    attributes: bodyAttributes(font: font, paragraphStyle: paragraph),
                    links: &links
                )
            }
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes(paragraphStyle: paragraph)))
        }
    }

    private func textAlignment(for alignment: ForgeMarkdownTableAlignment?) -> NSTextAlignment {
        switch alignment {
        case .center: .center
        case .right: .right
        case .left, nil: .left
        }
    }

    private func appendInlines(
        _ inlines: [ForgeMarkdownInline],
        to output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any],
        links: inout [URL: ForgeMarkdownLinkTarget]
    ) {
        for inline in inlines {
            switch inline {
            case let .text(text):
                output.append(NSAttributedString(string: text, attributes: attributes))
            case let .emphasis(children):
                appendInlines(
                    children,
                    to: output,
                    attributes: merging(attributes, [.obliqueness: 0.18]),
                    links: &links
                )
            case let .strong(children):
                let font = attributes[.font] as? NSFont ?? bodyFont
                appendInlines(
                    children,
                    to: output,
                    attributes: merging(attributes, [.font: font.withWeight(.semibold)]),
                    links: &links
                )
            case let .strikethrough(children):
                appendInlines(
                    children,
                    to: output,
                    attributes: merging(attributes, [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ]),
                    links: &links
                )
            case let .inlineCode(code):
                output.append(NSAttributedString(
                    string: code,
                    attributes: merging(attributes, [
                        .font: codeFont,
                        .backgroundColor: NSColor.controlBackgroundColor,
                    ])
                ))
            case .softBreak:
                output.append(NSAttributedString(string: " ", attributes: attributes))
            case .lineBreak:
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            case let .link(label, target):
                let token = URL(string: "x-gitx-markdown-link://\(UUID().uuidString)")!
                links[token] = target
                appendInlines(
                    label,
                    to: output,
                    attributes: merging(attributes, [
                        .link: token,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]),
                    links: &links
                )
            case let .imagePlaceholder(altText):
                let label = altText.isEmpty ? "▧ Image" : "▧ Image: \(altText)"
                output.append(NSAttributedString(
                    string: label,
                    attributes: merging(attributes, [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .backgroundColor: NSColor.controlBackgroundColor,
                    ])
                ))
            }
        }
    }

    private func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
        let clamped = min(max(level, 1), 6)
        let sizes: [CGFloat] = [22, 18, 16, 14, 13, 12]
        let weights: [NSFont.Weight] = [.bold, .bold, .semibold, .semibold, .medium, .medium]
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = clamped == 1 ? 10 : 7
        paragraph.paragraphSpacing = 4
        return bodyAttributes(
            font: NSFont.systemFont(ofSize: sizes[clamped - 1], weight: weights[clamped - 1]),
            paragraphStyle: paragraph
        )
    }

    private func bodyAttributes(
        font: NSFont? = nil,
        foregroundColor: NSColor = .labelColor,
        backgroundColor: NSColor? = nil,
        paragraphStyle: NSParagraphStyle? = nil
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = paragraphStyle ?? {
            let value = NSMutableParagraphStyle()
            value.lineSpacing = 2
            value.paragraphSpacing = 6
            return value
        }()
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? bodyFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph,
        ]
        if let backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }
        return attributes
    }

    private func merging(
        _ base: [NSAttributedString.Key: Any],
        _ additions: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        base.merging(additions) { _, replacement in replacement }
    }
}

@MainActor
final class ForgeMarkdownNativeView: NSView, NSTextViewDelegate {
    let textView = ForgeMarkdownTextView()
    weak var navigationRouter: ForgeMarkdownNavigationRouting?

    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeMarkdown")
    private let scrollView = NSScrollView()
    private var headingRanges: [ForgeMarkdownHeadingID: NSRange] = [:]
    private var linkTargets: [URL: ForgeMarkdownLinkTarget] = [:]

    init(
        document: ForgeMarkdownDocument,
        navigationRouter: ForgeMarkdownNavigationRouting? = nil,
        renderer: ForgeMarkdownNativeRenderer = ForgeMarkdownNativeRenderer()
    ) {
        self.navigationRouter = navigationRouter
        super.init(frame: .zero)
        configureViews()
        display(document, renderer: renderer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(
        _ document: ForgeMarkdownDocument,
        renderer: ForgeMarkdownNativeRenderer = ForgeMarkdownNativeRenderer()
    ) {
        let rendered = renderer.render(document)
        headingRanges = rendered.headingRanges
        linkTargets = rendered.linkTargets
        textView.textStorage?.setAttributedString(rendered.attributedString)
        textView.setAccessibilityLabel("Forge Markdown content")
        logger.debug(
            "Rendered sanitized Forge Markdown blocks=\(document.blocks.count, privacy: .public) headings=\(rendered.headingRanges.count, privacy: .public) links=\(rendered.linkTargets.count, privacy: .public)"
        )
    }

    @discardableResult
    func activateLink(_ link: Any) -> Bool {
        guard let url = link as? URL,
              let target = linkTargets[url]
        else {
            return false
        }
        switch target {
        case let .heading(identifier):
            guard let range = headingRanges[identifier] else { return false }
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
            logger.debug("Scrolled to sanitized Markdown heading")
        default:
            navigationRouter?.activateMarkdownLink(target)
            logger.debug("Requested sanitized Markdown link activation")
        }
        return true
    }

    func textView(
        _: NSTextView,
        clickedOnLink link: Any,
        at _: Int
    ) -> Bool {
        activateLink(link)
    }

    func markdownMenu(for event: NSEvent, fallback: NSMenu?) -> NSMenu? {
        guard let target = linkTarget(at: event.locationInWindow),
              case let .native(destination) = target,
              let browserURL = try? ForgeDestinationURLCodec.url(for: destination)
        else {
            return fallback
        }
        let menu = fallback ?? NSMenu()
        menu.addItem(.separator())
        let item = NSMenuItem(
            title: "Open in Browser",
            action: #selector(openInBrowser(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = browserURL
        menu.addItem(item)
        return menu
    }

    private func configureViews() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Forge Markdown")
        setAccessibilityIdentifier("ForgeMarkdownNativeView")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        textView.delegate = self
        textView.markdownOwner = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityIdentifier("ForgeMarkdownText")
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func linkTarget(at windowPoint: NSPoint) -> ForgeMarkdownLinkTarget? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }
        let point = textView.convert(windowPoint, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textView.textContainerOrigin.x,
            y: point.y - textView.textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textView.textStorage?.length ?? 0,
              let url = textView.textStorage?.attribute(
                  .link,
                  at: characterIndex,
                  effectiveRange: nil
              ) as? URL
        else {
            return nil
        }
        return linkTargets[url]
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigationRouter?.openMarkdownLinkInBrowser(url)
        logger.debug("Requested explicit browser escape for native Markdown link")
    }
}

@MainActor
final class ForgeMarkdownTextView: NSTextView {
    weak var markdownOwner: ForgeMarkdownNativeView?

    override func menu(for event: NSEvent) -> NSMenu? {
        let fallback = super.menu(for: event)
        return markdownOwner?.markdownMenu(for: event, fallback: fallback) ?? fallback
    }
}

private extension NSAttributedString.Key {
    static let forgeMarkdownHeading = NSAttributedString.Key("PBForgeMarkdownHeading")
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

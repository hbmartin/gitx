import Foundation
import Markdown

public struct ForgeMarkdownSanitizer: Sendable {
    private let linkPolicy: ForgeMarkdownLinkPolicy

    public init(linkPolicy: ForgeMarkdownLinkPolicy = ForgeMarkdownLinkPolicy()) {
        self.linkPolicy = linkPolicy
    }

    public func sanitize(
        _ markdown: String,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownDocument {
        // GitHub-flavored tables, task lists, and strikethrough remain enabled,
        // while smart punctuation is disabled to preserve Forge-authored text.
        return sanitize(
            Document(parsing: markdown, options: .disableSmartOpts),
            context: context
        )
    }

    func sanitize(
        _ parsed: Document,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownDocument {
        var slugger = ForgeMarkdownHeadingSlugger()
        return ForgeMarkdownDocument(
            blocks: sanitizeBlocks(parsed.children, context: context, slugger: &slugger)
        )
    }

    private func sanitizeBlocks(
        _ markups: MarkupChildren,
        context: ForgeMarkdownContext,
        slugger: inout ForgeMarkdownHeadingSlugger
    ) -> [ForgeMarkdownBlock] {
        markups.flatMap { sanitizeBlock($0, context: context, slugger: &slugger) }
    }

    private func sanitizeBlock(
        _ markup: Markup,
        context: ForgeMarkdownContext,
        slugger: inout ForgeMarkdownHeadingSlugger
    ) -> [ForgeMarkdownBlock] {
        switch markup {
        case let paragraph as Paragraph:
            return [.paragraph(sanitizeInlines(paragraph.children, context: context))]
        case let heading as Heading:
            let content = sanitizeInlines(heading.children, context: context)
            return [.heading(
                level: min(max(heading.level, 1), 6),
                identifier: slugger.identifier(for: plainText(content)),
                content: content
            )]
        case let quote as BlockQuote:
            return [.blockQuote(sanitizeBlocks(quote.children, context: context, slugger: &slugger))]
        case let list as UnorderedList:
            return [.unorderedList(list.children.compactMap { child in
                guard let item = child as? ListItem else { return nil }
                return sanitizeListItem(item, context: context, slugger: &slugger)
            })]
        case let list as OrderedList:
            return [.orderedList(
                start: list.startIndex,
                items: list.children.compactMap { child in
                    guard let item = child as? ListItem else { return nil }
                    return sanitizeListItem(item, context: context, slugger: &slugger)
                }
            )]
        case let code as CodeBlock:
            return [.codeBlock(language: sanitizedLanguage(code.language), code: code.code)]
        case is ThematicBreak:
            return [.thematicBreak]
        case let table as Table:
            return [.table(sanitizeTable(table, context: context))]
        case let html as HTMLBlock:
            return inertParagraph(html.rawHTML)
        default:
            // Fail closed for every node outside the accepted document model.
            // Descendant links and images are flattened to text, never visited
            // as active structures through swift-markdown's default visitor.
            return inertParagraph(inertText(markup))
        }
    }

    private func sanitizeListItem(
        _ item: ListItem,
        context: ForgeMarkdownContext,
        slugger: inout ForgeMarkdownHeadingSlugger
    ) -> ForgeMarkdownListItem {
        let taskState: ForgeMarkdownTaskState? = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case nil: nil
        }
        return ForgeMarkdownListItem(
            taskState: taskState,
            blocks: sanitizeBlocks(item.children, context: context, slugger: &slugger)
        )
    }

    private func sanitizeTable(
        _ table: Table,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownTable {
        ForgeMarkdownTable(
            columnAlignments: table.columnAlignments.map { alignment in
                switch alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                case nil: nil
                }
            },
            header: sanitizeTableCells(table.head.children, context: context),
            rows: table.body.rows.map { row in
                sanitizeTableCells(row.children, context: context)
            }
        )
    }

    private func sanitizeTableCells(
        _ cells: MarkupChildren,
        context: ForgeMarkdownContext
    ) -> [ForgeMarkdownTableCell] {
        cells.compactMap { markup in
            guard let cell = markup as? Table.Cell else { return nil }
            return ForgeMarkdownTableCell(
                columnSpan: cell.colspan,
                rowSpan: cell.rowspan,
                content: sanitizeInlines(cell.children, context: context)
            )
        }
    }

    private func sanitizeInlines(
        _ markups: MarkupChildren,
        context: ForgeMarkdownContext
    ) -> [ForgeMarkdownInline] {
        markups.flatMap { sanitizeInline($0, context: context) }
    }

    private func sanitizeInline(
        _ markup: Markup,
        context: ForgeMarkdownContext
    ) -> [ForgeMarkdownInline] {
        switch markup {
        case let text as Text:
            return [.text(text.string)]
        case let emphasis as Emphasis:
            return [.emphasis(sanitizeInlines(emphasis.children, context: context))]
        case let strong as Strong:
            return [.strong(sanitizeInlines(strong.children, context: context))]
        case let strikethrough as Strikethrough:
            return [.strikethrough(sanitizeInlines(strikethrough.children, context: context))]
        case let code as InlineCode:
            return [.inlineCode(code.code)]
        case is SoftBreak:
            return [.softBreak]
        case is LineBreak:
            return [.lineBreak]
        case let link as Link:
            let label = sanitizeInlines(link.children, context: context)
            guard let destination = link.destination,
                  let target = linkPolicy.target(for: destination, context: context)
            else {
                return label
            }
            return [.link(label: label, target: target)]
        case let image as Image:
            // The source is intentionally never read or copied into a GitX
            // value. Markdown images remain inert through Milestone 3.
            return [.imagePlaceholder(altText: inertText(image.children))]
        case let html as InlineHTML:
            return [.text(html.rawHTML)]
        case let custom as CustomInline:
            return [.text(custom.text)]
        case let symbol as SymbolLink:
            return [.text(symbol.plainText)]
        default:
            let text = inertText(markup)
            return text.isEmpty ? [] : [.text(text)]
        }
    }

    private func inertParagraph(_ text: String) -> [ForgeMarkdownBlock] {
        text.isEmpty ? [] : [.paragraph([.text(text)])]
    }

    private func inertText(_ markups: MarkupChildren) -> String {
        markups.map(inertText).joined()
    }

    private func inertText(_ markup: Markup) -> String {
        switch markup {
        case let text as Text: text.string
        case let html as InlineHTML: html.rawHTML
        case let html as HTMLBlock: html.rawHTML
        case let code as InlineCode: code.code
        case let code as CodeBlock: code.code
        case let custom as CustomInline: custom.text
        case is SoftBreak, is LineBreak: "\n"
        default: markup.children.map(inertText).joined()
        }
    }

    private func plainText(_ inlines: [ForgeMarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case let .text(text), let .inlineCode(text), let .imagePlaceholder(text): text
            case let .emphasis(children),
                 let .strong(children),
                 let .strikethrough(children),
                 let .link(children, _):
                plainText(children)
            case .softBreak, .lineBreak:
                " "
            }
        }.joined()
    }

    private func sanitizedLanguage(_ language: String?) -> String? {
        guard let candidate = language?.split(whereSeparator: \Character.isWhitespace).first.map(String.init),
              !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "_+.#-".unicodeScalars.contains($0)
              })
        else {
            return nil
        }
        return candidate
    }
}

@testable import ForgeKit
import Foundation
import Markdown
import XCTest

final class ForgeMarkdownSanitizerTests: XCTestCase {
    private let sanitizer = ForgeMarkdownSanitizer()

    func testSanitizesSupportedGitHubFlavoredStructureIntoOwnedValues() throws {
        let document = try sanitizer.sanitize(
            """
            # Heading

            Plain *emphasis* **strong** ~~removed~~ and `code`.\\
            Next line.

            > Quoted

            - [x] Complete
            - [ ] Pending

            3. Third
            4. Fourth

            | Left | Center | Right |
            | :--- | :----: | ----: |
            | A | B | C |

            ---

            ```swift extra
            <script>code remains code</script>
            ```
            """,
            context: context()
        )

        guard case let .heading(level, identifier, content) = document.blocks[0] else {
            return XCTFail("Expected heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(identifier.rawValue, "heading")
        XCTAssertEqual(content, [.text("Heading")])

        guard case let .paragraph(inlines) = document.blocks[1] else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.emphasis([.text("emphasis")])))
        XCTAssertTrue(inlines.contains(.strong([.text("strong")])))
        XCTAssertTrue(inlines.contains(.strikethrough([.text("removed")])))
        XCTAssertTrue(inlines.contains(.inlineCode("code")))
        XCTAssertTrue(inlines.contains(.lineBreak))

        guard case let .blockQuote(quote) = document.blocks[2] else {
            return XCTFail("Expected quote")
        }
        XCTAssertEqual(quote, [.paragraph([.text("Quoted")])])

        guard case let .unorderedList(tasks) = document.blocks[3] else {
            return XCTFail("Expected task list")
        }
        XCTAssertEqual(tasks.map(\.taskState), [.checked, .unchecked])

        guard case let .orderedList(start, items) = document.blocks[4] else {
            return XCTFail("Expected ordered list")
        }
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items.count, 2)

        guard case let .table(table) = document.blocks[5] else {
            return XCTFail("Expected table")
        }
        XCTAssertEqual(table.columnAlignments, [.left, .center, .right])
        XCTAssertEqual(table.header.map(\.content), [[.text("Left")], [.text("Center")], [.text("Right")]])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(document.blocks[6], .thematicBreak)
        XCTAssertEqual(
            document.blocks[7],
            .codeBlock(language: "swift", code: "<script>code remains code</script>\n")
        )
    }

    func testRawHTMLAndUnsafeLinksBecomeInertWhileImagesDiscardEverySource() throws {
        let document = try sanitizer.sanitize(
            """
            Text <script>alert('inert')</script> and [unsafe](javascript:alert(1)).

            <form action="https://active-form-secret.example"><input></form>

            ![Remote alt](https://image-host-secret.example/pixel.png)
            ![Local alt](file:///private/local-file-secret.png)
            ![Data alt](data:image/png;base64,data-secret)
            """,
            context: context()
        )

        let encoded = try JSONEncoder().encode(document)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains("image-host-secret"))
        XCTAssertFalse(serialized.contains("local-file-secret"))
        XCTAssertFalse(serialized.contains("data-secret"))
        XCTAssertTrue(serialized.contains("Remote alt"))
        XCTAssertTrue(serialized.contains("Local alt"))
        XCTAssertTrue(serialized.contains("Data alt"))

        let inlines = allInlines(in: document.blocks)
        XCTAssertTrue(inlines.contains(.text("<script>")))
        XCTAssertTrue(inlines.contains(.text("unsafe")))
        XCTAssertFalse(inlines.contains { inline in
            if case .link = inline {
                true
            } else {
                false
            }
        })
        XCTAssertEqual(
            inlines.compactMap { inline -> String? in
                if case let .imagePlaceholder(altText) = inline {
                    altText
                } else {
                    nil
                }
            },
            ["Remote alt", "Local alt", "Data alt"]
        )
    }

    func testLinksAndDuplicateHeadingFragmentsAreSanitizedThroughPolicy() throws {
        let document = try sanitizer.sanitize(
            """
            # Hello, World!
            # Hello World

            [local](#hello-world)
            [pull](https://github.com/acme/widgets/pull/7)
            [file](Docs/Guide.md#L2)
            [external](https://example.com/path)
            [mail](mailto:dev@example.com?subject=Hello)
            """,
            context: context()
        )

        guard case let .heading(_, firstID, _) = document.blocks[0],
              case let .heading(_, secondID, _) = document.blocks[1]
        else {
            return XCTFail("Expected headings")
        }
        XCTAssertEqual(firstID.rawValue, "hello-world")
        XCTAssertEqual(secondID.rawValue, "hello-world-1")

        let targets = allInlines(in: document.blocks).compactMap { inline -> ForgeMarkdownLinkTarget? in
            if case let .link(_, target) = inline {
                target
            } else {
                nil
            }
        }
        XCTAssertEqual(targets.count, 5)
        XCTAssertEqual(targets[0], .heading(firstID))
        guard case .native(.pullRequest) = targets[1],
              case .native(.file) = targets[2],
              case .https = targets[3],
              case .mailto = targets[4]
        else {
            return XCTFail("Expected validated link families")
        }
    }

    func testDocumentRoundTripsWithoutReintroducingParserTypesOrImageSources() throws {
        let original = try sanitizer.sanitize(
            "# Title\n\n![Alt](https://never-retained.example/a.png)\n",
            context: context()
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ForgeMarkdownDocument.self, from: data), original)
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("never-retained"))
    }

    func testConstructedUnsupportedParserNodesFailClosedWithoutActivatingDestinations() throws {
        let document = Document(
            CustomBlock(Paragraph(
                Text("custom "),
                Image(source: "https://never-retained.example/custom.png", title: nil, Text("image")),
                Link(destination: "https://never-activated.example", Text("link"))
            )),
            BlockDirective(
                name: "Unsafe",
                argumentText: "source=https://never-retained.example/directive.png",
                children: Paragraph(Text("directive body"))
            ),
            Paragraph(
                CustomInline("custom inline"),
                SymbolLink(destination: "Secret.symbol"),
                InlineAttributes(attributes: #"role=\"button\""#, Text("attributed"))
            )
        )

        let sanitized = try sanitizer.sanitize(document, context: context())
        let encoded = try JSONEncoder().encode(sanitized)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains("never-retained"))
        XCTAssertFalse(serialized.contains("never-activated"))
        XCTAssertTrue(serialized.contains("custom "))
        XCTAssertTrue(serialized.contains("image"))
        XCTAssertTrue(serialized.contains("link"))
        XCTAssertTrue(serialized.contains("directive body"))
        XCTAssertTrue(serialized.contains("custom inline"))
        XCTAssertTrue(serialized.contains("Secret.symbol"))
        XCTAssertTrue(serialized.contains("attributed"))
        XCTAssertFalse(allInlines(in: sanitized.blocks).contains { inline in
            if case .link = inline {
                true
            } else {
                false
            }
        })
    }

    func testHeadingPlainTextRecursesAndInvalidCodeLanguagesAreRemoved() throws {
        let document = Document(
            Heading(
                level: 2,
                Emphasis(Text("emphasis")),
                Strong(Text(" strong")),
                Strikethrough(Text(" removed")),
                Link(destination: "#target", Text(" linked")),
                SoftBreak(),
                Text("next")
            ),
            CodeBlock(language: "bad! language", "code\n"),
            CodeBlock(language: nil, "plain\n")
        )
        let sanitized = try sanitizer.sanitize(document, context: context())

        guard case let .heading(_, identifier, _) = sanitized.blocks[0] else {
            return XCTFail("Expected heading")
        }
        XCTAssertEqual(identifier.rawValue, "emphasis-strong-removed-linked-next")
        XCTAssertEqual(
            sanitized.blocks[1],
            ForgeMarkdownBlock.codeBlock(language: nil, code: "code\n")
        )
        XCTAssertEqual(
            sanitized.blocks[2],
            ForgeMarkdownBlock.codeBlock(language: nil, code: "plain\n")
        )
    }

    private func context() throws -> ForgeMarkdownContext {
        try ForgeMarkdownContext(
            repository: TestSupport.repository(),
            location: .repository(defaultBranch: .branch(TestSupport.main))
        )
    }

    private func allInlines(in blocks: [ForgeMarkdownBlock]) -> [ForgeMarkdownInline] {
        blocks.flatMap { block -> [ForgeMarkdownInline] in
            return switch block {
            case let .paragraph(inlines), let .heading(_, _, inlines):
                nestedInlines(inlines)
            case let .blockQuote(children):
                allInlines(in: children)
            case let .unorderedList(items), let .orderedList(_, items):
                items.flatMap { allInlines(in: $0.blocks) }
            case let .table(table):
                (table.header + table.rows.flatMap { $0 }).flatMap { nestedInlines($0.content) }
            case .thematicBreak, .codeBlock:
                []
            }
        }
    }

    private func nestedInlines(_ inlines: [ForgeMarkdownInline]) -> [ForgeMarkdownInline] {
        inlines.flatMap { inline -> [ForgeMarkdownInline] in
            return switch inline {
            case let .emphasis(children),
                 let .strong(children),
                 let .strikethrough(children),
                 let .link(children, _):
                [inline] + nestedInlines(children)
            default:
                [inline]
            }
        }
    }
}

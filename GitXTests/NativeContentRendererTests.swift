import AppKit
import XCTest

final class NativeContentRendererTests: XCTestCase {
    private func preserveDefault(_ key: String) -> () -> Void {
        let original = UserDefaults.standard.object(forKey: key)
        return {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func font(
        in attributedString: NSAttributedString,
        matching text: String,
        offset: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSFont {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        XCTAssertGreaterThan(range.length, offset, file: file, line: line)
        return try XCTUnwrap(
            attributedString.attribute(
                .font,
                at: range.location + offset,
                effectiveRange: nil
            ) as? NSFont,
            file: file,
            line: line
        )
    }

    private func firstFont(
        in attributedString: NSAttributedString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSFont {
        var result: NSFont?
        attributedString.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            if let font = value as? NSFont {
                result = font
                stop.pointee = true
            }
        }
        return try XCTUnwrap(result, file: file, line: line)
    }

    @MainActor
    private func waitForText(_ text: String, in view: PBNativeContentView) {
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in view.textView.string.contains(text) },
            object: view.textView
        )
        wait(for: [rendered], timeout: 10)
    }

    @MainActor
    private func visibleCharacterIndex(in view: PBNativeContentView) throws -> Int {
        let layoutManager = try XCTUnwrap(view.textView.layoutManager)
        let textContainer = try XCTUnwrap(view.textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let visibleRect = view.textView.visibleRect
        let point = NSPoint(
            x: visibleRect.minX - view.textView.textContainerOrigin.x,
            y: visibleRect.minY - view.textView.textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    @MainActor
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants(of:))
    }

    private func role(
        in attributedString: NSAttributedString,
        matching text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        return try XCTUnwrap(
            attributedString.attribute(
                NSAttributedString.Key("PBNativeContentTypographyRole"),
                at: range.location,
                effectiveRange: nil
            ) as? String,
            file: file,
            line: line
        )
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    func testTextRendererBuildsSourceBlameAndHistoryResults() {
        let renderer = PBNativeTextRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes
        )
        let source = PBNativeContentSection(dictionary: [
            PBNativeSectionPathKey: "Example.swift",
            PBNativeSectionTextKey: "let value = 42\n",
        ])
        let sourceResult = renderer.renderSourceSections([source])
        XCTAssertTrue(sourceResult.attributedString.string.contains("Example.swift"))
        XCTAssertTrue(sourceResult.attributedString.string.contains("let value = 42"))
        XCTAssertTrue(sourceResult.linkPayloads.isEmpty)

        let sha = "0123456789abcdef0123456789abcdef01234567"
        let blame = PBNativeContentSection(dictionary: [
            PBNativeSectionPathKey: "Example.swift",
            PBNativeSectionTextKey: "\(sha) 1 1 1\nauthor An Extremely Long Author Name\nsummary First\n\tlet first = 1\n\(sha) 2 2\n\tlet second = 2\n",
        ])
        let blameResult = renderer.renderBlameSections([blame])
        XCTAssertTrue(blameResult.attributedString.string.contains("01234567"))
        XCTAssertTrue(blameResult.attributedString.string.contains("An Extremely Long…"))
        XCTAssertTrue(blameResult.attributedString.string.contains("let second = 2"))

        let history = PBNativeContentSection(dictionary: [
            PBNativeSectionTitleKey: "History",
            PBNativeSectionEntriesKey: [[
                "subject": "Subject",
                "author": "Ada",
                "date": "Today",
                "sha": sha,
            ]],
        ])
        let historyResult = renderer.renderHistorySections([history])
        XCTAssertTrue(historyResult.attributedString.string.contains("Ada  •  Today  •  0123456789ab"))
        XCTAssertEqual(historyResult.linkPayloads.values.first?["type"] as? String, "commit")
        XCTAssertEqual(historyResult.linkPayloads.values.first?["sha"] as? String, sha)
    }

    func testDiffFontSettingsPersistClampAndProvidePlainThemeFallback() throws {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        let restoreTheme = preserveDefault("PBSyntaxTheme")
        defer {
            restoreTheme()
            restoreSize()
            restoreName()
        }

        UserDefaults.standard.removeObject(forKey: "PBDiffFontName")
        UserDefaults.standard.removeObject(forKey: "PBDiffFontSize")
        XCTAssertEqual(
            PBApplicationSettings.diffFontName,
            NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
        )
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 12)

        PBApplicationSettings.diffFontName = "Configured Font"
        PBApplicationSettings.diffFontSize = 8
        XCTAssertEqual(PBApplicationSettings.diffFontName, "Configured Font")
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 9)
        PBApplicationSettings.diffFontSize = 72
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 36)

        UserDefaults.standard.set(-100, forKey: "PBDiffFontSize")
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 9)
        UserDefaults.standard.set(100, forKey: "PBDiffFontSize")
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 36)

        PBApplicationSettings.syntaxTheme = .plain
        PBApplicationSettings.diffFontName = "Definitely Not An Installed Font"
        PBApplicationSettings.diffFontSize = 17
        let fallback = try firstFont(
            in: PBHighlighting.highlightedString(forText: "plain text", path: "Example.swift")
        )
        XCTAssertEqual(fallback.pointSize, 17)
        XCTAssertTrue(fallback.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testEverySyntaxThemeUsesConfiguredFontFamilyAndSize() throws {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        let restoreTheme = preserveDefault("PBSyntaxTheme")
        defer {
            restoreTheme()
            restoreSize()
            restoreName()
        }
        PBApplicationSettings.diffFontName = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        ).fontName

        PBApplicationSettings.syntaxTheme = .plain
        PBApplicationSettings.diffFontSize = 9
        let smallPlain = try firstFont(
            in: PBHighlighting.highlightedString(forText: "let value = 1", path: "Example.swift")
        )
        PBApplicationSettings.diffFontSize = 36
        let largePlain = try firstFont(
            in: PBHighlighting.highlightedString(forText: "let value = 1", path: "Example.swift")
        )
        XCTAssertEqual(smallPlain.pointSize, 9)
        XCTAssertEqual(largePlain.pointSize, 36)

        for theme in [PBSyntaxTheme.xcode, .github] {
            PBApplicationSettings.syntaxTheme = theme
            PBApplicationSettings.diffFontSize = 9
            let smallHighlighted = try firstFont(
                in: PBHighlighting.highlightedString(forText: "let value = 1", path: "Example.swift")
            )
            PBApplicationSettings.diffFontSize = 36
            let largeHighlighted = try firstFont(
                in: PBHighlighting.highlightedString(forText: "let value = 1", path: "Example.swift")
            )

            XCTAssertEqual(smallHighlighted.pointSize, 9)
            XCTAssertEqual(largeHighlighted.pointSize, 36)
            XCTAssertEqual(smallHighlighted.familyName, smallPlain.familyName)
            XCTAssertEqual(largeHighlighted.familyName, largePlain.familyName)
        }
    }

    func testTypographyPreservesItalicSyntaxTraits() throws {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        let restoreTheme = preserveDefault("PBSyntaxTheme")
        defer {
            restoreTheme()
            restoreSize()
            restoreName()
        }
        PBApplicationSettings.diffFontName = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        ).fontName
        PBApplicationSettings.diffFontSize = 18
        PBApplicationSettings.syntaxTheme = .xcode

        let highlighted = PBHighlighting.highlightedString(
            forText: "*emphasis*",
            path: "README.md"
        )
        let emphasisFont = try font(in: highlighted, matching: "emphasis")

        XCTAssertEqual(emphasisFont.pointSize, 18)
        XCTAssertTrue(
            NSFontManager.shared.traits(of: emphasisFont).contains(.italicFontMask)
        )
    }

    func testTextRendererUsesTwelvePointFallbackWhenBaseFontIsAbsent() throws {
        let renderer = PBNativeTextRenderer(
            baseAttributes: [.foregroundColor: NSColor.textColor],
            titleAttributes: [.foregroundColor: NSColor.labelColor]
        )
        let rendered = renderer.renderSourceSections([
            PBNativeContentSection(dictionary: [
                PBNativeSectionPathKey: "Fallback.txt",
                PBNativeSectionTextKey: "fallback body\n",
            ]),
        ]).attributedString

        let bodyFont = try font(in: rendered, matching: "fallback body")
        XCTAssertEqual(bodyFont.pointSize, 12)
        XCTAssertTrue(
            NSFontManager.shared.traits(of: bodyFont).contains(.fixedPitchFontMask)
        )
        XCTAssertEqual(try font(in: rendered, matching: "Fallback.txt").pointSize, 13)
    }

    func testRenderersScaleEveryTypographyRoleRelativeToConfiguredSize() throws {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        let restoreTheme = preserveDefault("PBSyntaxTheme")
        defer {
            restoreTheme()
            restoreSize()
            restoreName()
        }
        PBApplicationSettings.syntaxTheme = .plain
        PBApplicationSettings.diffFontName = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        ).fontName
        PBApplicationSettings.diffFontSize = 18

        let scaledBaseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        let scaledTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]

        let textRenderer = PBNativeTextRenderer(
            baseAttributes: scaledBaseAttributes,
            titleAttributes: scaledTitleAttributes
        )
        let source = textRenderer.renderSourceSections([
            PBNativeContentSection(dictionary: [
                PBNativeSectionPathKey: "Example.swift",
                PBNativeSectionTextKey: "let value = 42\n",
            ]),
        ]).attributedString
        XCTAssertEqual(try font(in: source, matching: "Example.swift").pointSize, 19)
        XCTAssertEqual(try role(in: source, matching: "Example.swift"), "title")
        XCTAssertEqual(try font(in: source, matching: "let value").pointSize, 18)
        XCTAssertEqual(try role(in: source, matching: "let value"), "body")

        let sha = "0123456789abcdef0123456789abcdef01234567"
        let blame = textRenderer.renderBlameSections([
            PBNativeContentSection(dictionary: [
                PBNativeSectionPathKey: "Blame.swift",
                PBNativeSectionTextKey: "\(sha) 1 1 1\nauthor Ada\nsummary First\n\tlet blamed = true\n",
            ]),
        ]).attributedString
        XCTAssertEqual(try font(in: blame, matching: "Blame.swift").pointSize, 19)
        XCTAssertEqual(try font(in: blame, matching: "01234567").pointSize, 17)
        XCTAssertEqual(try role(in: blame, matching: "01234567"), "blameGutter")
        XCTAssertEqual(try font(in: blame, matching: "let blamed").pointSize, 18)

        let historyResult = textRenderer.renderHistorySections([
            PBNativeContentSection(dictionary: [
                PBNativeSectionTitleKey: "History",
                PBNativeSectionEntriesKey: [[
                    "subject": "Subject",
                    "author": "Ada",
                    "date": "Today",
                    "sha": sha,
                ]],
            ]),
        ])
        XCTAssertEqual(try font(in: historyResult.attributedString, matching: "History").pointSize, 19)
        XCTAssertEqual(try font(in: historyResult.attributedString, matching: "Subject").pointSize, 19)
        XCTAssertEqual(try font(in: historyResult.attributedString, matching: "Ada").pointSize, 17)
        XCTAssertEqual(try role(in: historyResult.attributedString, matching: "Ada"), "metadata")
        XCTAssertEqual(
            try font(in: historyResult.attributedString, matching: "0123456789ab").pointSize,
            17
        )
        XCTAssertEqual(
            try role(in: historyResult.attributedString, matching: "0123456789ab"),
            "link"
        )
        let historyLinkRange = (historyResult.attributedString.string as NSString)
            .range(of: "0123456789ab")
        let historyLink = historyResult.attributedString.attribute(
            .link,
            at: historyLinkRange.location,
            effectiveRange: nil
        )
        XCTAssertNotNil(historyLink)
        XCTAssertEqual(historyResult.linkPayloads.values.first?["sha"] as? String, sha)

        let diff = """
        diff --git a/Example.swift b/Example.swift
        --- a/Example.swift
        +++ b/Example.swift
        @@ -1 +1 @@
        -let old = 1
        +let new = 2

        """
        let diffRenderer = PBNativeDiffRenderer(
            baseAttributes: scaledBaseAttributes,
            titleAttributes: scaledTitleAttributes,
            parser: PBDiffDocumentParser()
        )
        let unified = diffRenderer.renderSections(
            [PBNativeContentSection(dictionary: [
                PBNativeSectionTextKey: diff,
                PBNativeSectionContextKey: "unstaged",
                PBNativeSectionDiffLayoutKey: 0,
            ])],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        ).attributedString
        XCTAssertEqual(try font(in: unified, matching: "Example.swift").pointSize, 19)
        XCTAssertEqual(try font(in: unified, matching: "@@ -1 +1 @@").pointSize, 18)
        XCTAssertEqual(try font(in: unified, matching: "Stage hunk").pointSize, 17)
        XCTAssertEqual(try role(in: unified, matching: "Stage hunk"), "link")

        let sideBySide = diffRenderer.renderSections(
            [PBNativeContentSection(dictionary: [
                PBNativeSectionTextKey: diff,
                PBNativeSectionContextKey: "readOnly",
                PBNativeSectionDiffLayoutKey: 1,
            ])],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        ).attributedString
        XCTAssertEqual(try font(in: sideBySide, matching: "Before").pointSize, 16)
        XCTAssertEqual(try role(in: sideBySide, matching: "Before"), "sideHeader")
        XCTAssertEqual(try font(in: sideBySide, matching: " │ ").pointSize, 18)
        XCTAssertEqual(try role(in: sideBySide, matching: " │ "), "sideSeparator")
    }

    @MainActor
    func testCachedDiffPreservesScrollAndSelection() throws {
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        var diff = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1,200 +1,200 @@

        """
        for index in 0 ..< 200 {
            diff += "-old-\(index)\n+new-\(index)\n"
        }
        let sections: [[String: Any]] = [[
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "readOnly",
        ]]

        view.showDiffSections(
            sections,
            cacheIdentifier: "font-characterization",
            preserveScrollPosition: true
        )
        waitForText("new-199", in: view)
        window.layoutIfNeeded()

        let scrollView = try XCTUnwrap(view.textView.enclosingScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        let maximumY = max(
            0,
            documentView.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY * 0.65))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let expectedY = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(expectedY, 0)

        let selection = (view.textView.string as NSString).range(of: "new-150")
        XCTAssertNotEqual(selection.location, NSNotFound)
        view.textView.setSelectedRange(selection)

        view.showDiffSections(
            sections,
            cacheIdentifier: "font-characterization",
            preserveScrollPosition: true
        )

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, expectedY, accuracy: 1)
        XCTAssertEqual(view.textView.selectedRange(), selection)
    }

    func testEffectiveDiffFontChangesPostTypographyNotification() {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        defer {
            restoreSize()
            restoreName()
        }
        let defaultName = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        ).fontName
        UserDefaults.standard.set(defaultName, forKey: "PBDiffFontName")
        UserDefaults.standard.set(12, forKey: "PBDiffFontSize")
        let changed = expectation(description: "typography setting changed")
        changed.expectedFulfillmentCount = 2
        changed.assertForOverFulfill = true
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("PBDiffTextTypographyDidChangeNotification"),
            object: nil,
            queue: nil
        ) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        PBApplicationSettings.diffFontSize = 12
        PBApplicationSettings.diffFontName = defaultName
        PBApplicationSettings.diffFontSize = 18
        PBApplicationSettings.diffFontName = "Menlo"

        wait(for: [changed], timeout: 0.1)
    }

    @MainActor
    func testLiveFontChangeRestylesDiffAndPreservesSelectionAndViewport() throws {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        let restoreTheme = preserveDefault("PBSyntaxTheme")
        defer {
            restoreTheme()
            restoreSize()
            restoreName()
        }
        let initialName = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        ).fontName
        UserDefaults.standard.set(initialName, forKey: "PBDiffFontName")
        UserDefaults.standard.set(12, forKey: "PBDiffFontSize")
        UserDefaults.standard.set(PBSyntaxTheme.xcode.rawValue, forKey: "PBSyntaxTheme")

        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        XCTAssertEqual(view.textView.accessibilityIdentifier(), "NativeContentText")
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        var diff = """
        diff --git a/Example.swift b/Example.swift
        --- a/Example.swift
        +++ b/Example.swift
        @@ -1,200 +1,200 @@

        """
        for index in 0 ..< 200 {
            diff += "-let old\(index) = \(index)\n+let new\(index) = \(index + 1)\n"
        }
        view.showDiffSections([
            [
                PBNativeSectionTextKey: diff,
                PBNativeSectionContextKey: "unstaged",
            ],
        ])
        waitForText("let new199 = 200", in: view)
        window.layoutIfNeeded()

        let scrollView = try XCTUnwrap(view.textView.enclosingScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        let maximumY = max(
            0,
            documentView.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY * 0.55))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let selection = (view.textView.string as NSString).range(of: "let new150 = 151")
        XCTAssertNotEqual(selection.location, NSNotFound)
        view.textView.setSelectedRange(selection)
        let visibleCharacter = try visibleCharacterIndex(in: view)

        PBApplicationSettings.diffFontSize = 18

        XCTAssertEqual(view.textView.selectedRange(), selection)
        XCTAssertEqual(try visibleCharacterIndex(in: view), visibleCharacter)
        XCTAssertEqual(try font(in: view.textView.attributedString(), matching: "Example.swift").pointSize, 19)
        XCTAssertEqual(try font(in: view.textView.attributedString(), matching: "Stage hunk").pointSize, 17)
        XCTAssertEqual(try font(in: view.textView.attributedString(), matching: "let new150").pointSize, 18)

        PBApplicationSettings.diffFontName = "Menlo"

        let expectedFamily = try XCTUnwrap(NSFont(name: "Menlo", size: 18)).familyName
        XCTAssertEqual(
            try font(
                in: view.textView.attributedString(),
                matching: "let new150"
            ).familyName,
            expectedFamily
        )
        XCTAssertEqual(view.textView.selectedRange(), selection)
        XCTAssertEqual(try visibleCharacterIndex(in: view), visibleCharacter)
    }

    @MainActor
    func testBackgroundFontChangeRerendersOnMainThread() throws {
        let restoreName = preserveDefault("PBDiffFontName")
        let restoreSize = preserveDefault("PBDiffFontSize")
        defer {
            restoreSize()
            restoreName()
        }
        let initialName = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        ).fontName
        UserDefaults.standard.set(initialName, forKey: "PBDiffFontName")
        UserDefaults.standard.set(12, forKey: "PBDiffFontSize")

        let view = PBNativeContentView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 120)
        )
        view.showMessage("Loading")
        XCTAssertEqual(
            try font(in: view.textView.attributedString(), matching: "Loading")
                .pointSize,
            13
        )
        let rerendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let attributedString = view.textView.attributedString()
                guard attributedString.length > 0,
                      let font = attributedString.attribute(
                          .font,
                          at: 0,
                          effectiveRange: nil
                      ) as? NSFont
                else {
                    return false
                }
                return font.pointSize == 19
            },
            object: view
        )

        DispatchQueue.global(qos: .userInitiated).async {
            PBApplicationSettings.diffFontSize = 18
        }

        wait(for: [rerendered], timeout: 10)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(try role(in: view.textView.attributedString(), matching: "Loading"), "status")
    }

    @MainActor
    func testDiffSettingsControlsKeepSemanticSystemTypographyAtLargeDiffSize() throws {
        let restoreSize = preserveDefault("PBDiffFontSize")
        defer { restoreSize() }
        UserDefaults.standard.set(36, forKey: "PBDiffFontSize")

        let settings = PBSettingsViewFactory.diffAndTextView()
        settings.layoutSubtreeIfNeeded()
        let views = [settings] + descendants(of: settings)
        let heading = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "SettingsPaneHeading"
        })
        let preferredHeading = NSFont.preferredFont(
            forTextStyle: .headline,
            options: [:]
        )
        XCTAssertEqual(heading.font?.fontName, preferredHeading.fontName)
        XCTAssertEqual(heading.font?.pointSize, preferredHeading.pointSize)
        XCTAssertNotEqual(
            heading.font?.pointSize,
            CGFloat(PBApplicationSettings.diffFontSize)
        )

        for identifier in [
            "DiffFontFamily",
            "DiffFontSizeStepper",
            "DiffFontSizeValue",
        ] {
            XCTAssertTrue(views.contains {
                $0.accessibilityIdentifier() == identifier
            })
        }
        XCTAssertGreaterThanOrEqual(settings.frame.width, settings.fittingSize.width)
        XCTAssertGreaterThanOrEqual(settings.frame.height, settings.fittingSize.height)
    }

    func testDiffRendererBuildsTypedActionsAndCollapsedResults() {
        let parser = PBDiffDocumentParser()
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: parser
        )
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 2
         tail

        """
        let section = PBNativeContentSection(dictionary: [
            PBNativeSectionTitleKey: "Changes",
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "unstaged",
            PBNativeSectionDiffLayoutKey: 0,
        ])

        let result = renderer.renderSections(
            [section],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )

        XCTAssertTrue(result.attributedString.string.contains("Stage hunk"))
        XCTAssertTrue(result.attributedString.string.contains("Discard line"))
        XCTAssertFalse(result.attributedString.string.contains("index 1111111..2222222 100644"))
        XCTAssertTrue(result.linkPayloads.values.contains { $0["action"] as? String == "stage" })
        XCTAssertTrue(result.linkPayloads.values.contains { $0["selectedIndexes"] is IndexSet })

        let collapsed = renderer.renderSections(
            [section],
            collapsedFiles: ["0:file.swift"],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(collapsed.attributedString.string.contains("▸ file.swift"))
        XCTAssertFalse(collapsed.attributedString.string.contains("let new = 2"))
    }

    func testDiffRendererHandlesEmptyAndReadOnlySections() {
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: PBDiffDocumentParser()
        )
        let empty = PBNativeContentSection(dictionary: [PBNativeSectionTitleKey: "Empty"])
        let readOnly = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
        ])

        let result = renderer.renderSections(
            [empty, readOnly],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )

        XCTAssertTrue(result.attributedString.string.contains("There are no differences."))
        XCTAssertTrue(result.attributedString.string.contains("+new"))
        XCTAssertFalse(result.attributedString.string.contains("Stage line"))
    }

    func testDiffRendererSupportsSideBySideAndSuppressedFiles() {
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: PBDiffDocumentParser()
        )
        let diff = """
        diff --git a/generated/output.swift b/generated/output.swift
        index 1111111..2222222 100644
        --- a/generated/output.swift
        +++ b/generated/output.swift
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 2
         tail

        """
        let sideBySide = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "unstaged",
            PBNativeSectionDiffLayoutKey: 1,
        ])
        let sideBySideResult = renderer.renderSections(
            [sideBySide],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(sideBySideResult.attributedString.string.contains("Before"))
        XCTAssertTrue(sideBySideResult.attributedString.string.contains("After"))
        XCTAssertTrue(sideBySideResult.attributedString.string.contains("Stage hunk"))
        XCTAssertFalse(sideBySideResult.attributedString.string.contains("index 1111111..2222222 100644"))

        let suppressed = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: "unstaged",
            PBNativeSectionSuppressionPatternsKey: [#"^generated/"#],
        ])
        let suppressedResult = renderer.renderSections(
            [suppressed],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(suppressedResult.attributedString.string.contains("Diff hidden by repository setting"))
        XCTAssertFalse(suppressedResult.attributedString.string.contains("let new = 2"))

        let revealedResult = renderer.renderSections(
            [suppressed],
            collapsedFiles: [],
            expandedImages: ["suppression:0:generated/output.swift"],
            imageDataProvider: nil
        )
        XCTAssertTrue(revealedResult.attributedString.string.contains("let new = 2"))
    }

    @MainActor
    func testSideBySideTruncatesLongSyntaxLinesAndRendersImagesOnMainThread() throws {
        let renderer = PBNativeDiffRenderer(
            baseAttributes: baseAttributes,
            titleAttributes: titleAttributes,
            parser: PBDiffDocumentParser()
        )
        let longValue = String(repeating: "value", count: 20)
        let textDiff = """
        diff --git a/Long.swift b/Long.swift
        --- a/Long.swift
        +++ b/Long.swift
        @@ -1 +1 @@
        -let old = \(longValue)
        +let new = \(longValue)
        \\ No newline at end of file

        """
        let sideBySide = PBNativeContentSection(dictionary: [
            PBNativeSectionTextKey: textDiff,
            PBNativeSectionContextKey: "readOnly",
            PBNativeSectionDiffLayoutKey: 1,
        ])
        let textResult = renderer.renderSections(
            [sideBySide],
            collapsedFiles: [],
            expandedImages: [],
            imageDataProvider: nil
        )
        XCTAssertTrue(textResult.attributedString.string.contains("…"))
        XCTAssertFalse(textResult.attributedString.string.contains(longValue))

        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let imageData = try XCTUnwrap(image.tiffRepresentation)
        let imageDiff = "diff --git a/image.png b/image.png\nBinary files a/image.png and b/image.png differ\n"
        let imageSection = PBNativeContentSection(dictionary: [PBNativeSectionTextKey: imageDiff])
        let imageResult = renderer.renderSections(
            [imageSection],
            collapsedFiles: [],
            expandedImages: ["0:image.png"],
            imageDataProvider: { _, _, _ in imageData }
        )
        XCTAssertTrue((0 ..< imageResult.attributedString.length).contains {
            imageResult.attributedString.attribute(.attachment, at: $0, effectiveRange: nil) != nil
        })
    }
}

import AppKit

nonisolated enum NativeContentTypographyRole: String, CaseIterable {
    case title
    case body
    case metadata
    case link
    case blameGutter
    case sideHeader
    case sideSeparator
    case status

    var sizeOffset: CGFloat {
        switch self {
        case .title, .status:
            1
        case .body, .sideSeparator:
            0
        case .metadata, .link, .blameGutter:
            -1
        case .sideHeader:
            -2
        }
    }

    var weight: NSFont.Weight? {
        switch self {
        case .title, .sideHeader:
            .semibold
        case .link:
            .medium
        case .body, .metadata, .blameGutter, .sideSeparator, .status:
            nil
        }
    }
}

extension NSAttributedString.Key {
    nonisolated static let nativeContentTypographyRole = NSAttributedString.Key(
        "PBNativeContentTypographyRole"
    )
}

@objc(PBNativeContentTypography)
final nonisolated class NativeContentTypography: NSObject {
    private let baseFont: NSFont
    @objc let baseSize: CGFloat

    @objc(initWithFontName:baseSize:)
    init(fontName: String, baseSize: CGFloat) {
        self.baseSize = min(36, max(9, baseSize))
        baseFont = NSFont(
            name: fontName,
            size: self.baseSize
        ) ?? NSFont.monospacedSystemFont(
            ofSize: self.baseSize,
            weight: .regular
        )
        super.init()
    }

    @objc(currentTypography)
    static func currentTypography() -> NativeContentTypography {
        NativeContentTypography(
            fontName: ApplicationSettings.diffFontName,
            baseSize: ApplicationSettings.diffFontSize
        )
    }

    @objc var bodyAttributes: [NSAttributedString.Key: Any] {
        attributes(
            for: .body,
            merging: [.foregroundColor: NSColor.textColor]
        )
    }

    @objc var titleAttributes: [NSAttributedString.Key: Any] {
        attributes(
            for: .title,
            merging: [.foregroundColor: NSColor.labelColor]
        )
    }

    @objc var statusAttributes: [NSAttributedString.Key: Any] {
        attributes(
            for: .status,
            merging: [.foregroundColor: NSColor.secondaryLabelColor]
        )
    }

    func attributes(
        for role: NativeContentTypographyRole,
        merging attributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[.font] = font(
            for: role,
            preservingTraitsOf: attributes[.font] as? NSFont
        )
        result[.nativeContentTypographyRole] = role.rawValue
        return result
    }

    func styledString(
        _ attributedString: NSAttributedString,
        role: NativeContentTypographyRole
    ) -> NSAttributedString {
        guard attributedString.length > 0 else { return attributedString }
        let result = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: attributedString.length)
        result.addAttribute(
            .nativeContentTypographyRole,
            value: role.rawValue,
            range: fullRange
        )
        result.addAttribute(.font, value: font(for: role), range: fullRange)
        attributedString.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            result.addAttribute(
                .font,
                value: self.font(
                    for: role,
                    preservingTraitsOf: value as? NSFont
                ),
                range: range
            )
        }
        return result
    }

    /// Invoked from PBNativeContentView's Objective-C wiring.
    @objc(restyledString:)
    func restyledString(_ attributedString: NSAttributedString) -> NSAttributedString { // swiftlint:disable:this unused_declaration
        guard attributedString.length > 0 else { return attributedString }
        if usesCurrentTypography(attributedString) {
            return attributedString
        }
        let fullRange = NSRange(location: 0, length: attributedString.length)
        var runs: [(role: NativeContentTypographyRole, font: NSFont?, range: NSRange)] = []
        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let role = (attributes[.nativeContentTypographyRole] as? String)
                .flatMap(NativeContentTypographyRole.init(rawValue:)) ?? .body
            runs.append((role, attributes[.font] as? NSFont, range))
        }
        let result = NSMutableAttributedString(attributedString: attributedString)
        for run in runs {
            result.addAttribute(
                .nativeContentTypographyRole,
                value: run.role.rawValue,
                range: run.range
            )
            result.addAttribute(
                .font,
                value: font(
                    for: run.role,
                    preservingTraitsOf: run.font
                ),
                range: run.range
            )
        }
        return result
    }

    private func usesCurrentTypography(_ attributedString: NSAttributedString) -> Bool {
        let attributes = attributedString.attributes(at: 0, effectiveRange: nil)
        guard let existingFont = attributes[.font] as? NSFont,
              let roleName = attributes[.nativeContentTypographyRole] as? String,
              let role = NativeContentTypographyRole(rawValue: roleName)
        else {
            return false
        }
        let expectedFont = font(for: role, preservingTraitsOf: existingFont)
        return existingFont.fontName == expectedFont.fontName &&
            existingFont.pointSize == expectedFont.pointSize
    }

    private func font(
        for role: NativeContentTypographyRole,
        preservingTraitsOf existingFont: NSFont? = nil
    ) -> NSFont {
        let pointSize = baseSize + role.sizeOffset
        var font = baseFont.withSize(pointSize)
        if let weight = role.weight {
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: weight],
            ])
            if let weightedFont = NSFont(descriptor: descriptor, size: pointSize) {
                font = weightedFont
            }
        }
        guard let existingFont else { return font }
        let existingTraits = existingFont.fontDescriptor.symbolicTraits
        var targetTraits = font.fontDescriptor.symbolicTraits
        if existingTraits.contains(.bold) {
            targetTraits.insert(.bold)
        }
        if existingTraits.contains(.italic) {
            targetTraits.insert(.italic)
        }
        let descriptor = font.fontDescriptor.withSymbolicTraits(targetTraits)
        if let traitFont = NSFont(descriptor: descriptor, size: pointSize) {
            font = traitFont
        }
        return font
    }
}

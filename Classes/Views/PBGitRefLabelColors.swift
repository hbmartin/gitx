import AppKit

// Objective-C graph drawing calls this through the generated Swift interface.
// swiftlint:disable unused_declaration
@objc(PBGitRefLabelColors)
final class RefLabelColors: NSObject {
    @objc(colorForRef:repository:)
    static func color(for ref: PBGitRef, repository: PBGitRepository?) -> NSColor {
        if ref.ref == repository?.headRef()?.simpleRef() {
            return rgb(0xFC, 0xA6, 0x4F)
        }
        if ref.isBranch, repository?.worktreeHoldingRef(ref) != nil {
            return rgb(0x8F, 0xE0, 0xD5)
        }
        switch ref.type {
        case "head": return rgb(0x9A, 0xE2, 0x84)
        case "remote": return rgb(0xA2, 0xCF, 0xEF)
        case "tag": return rgb(0xFC, 0xED, 0x6F)
        default: return .yellow
        }
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red / 256, green: green / 256, blue: blue / 256, alpha: 1)
    }
}

// swiftlint:enable unused_declaration

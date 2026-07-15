import Cocoa
import HighlightKit

@objc(PBHighlighting)
final class PBHighlighting: NSObject {
    private static let maximumHighlightedDiffByteCount = 200 * 1024

    private static let extensionLanguages: [String: String] = [
        "ada": "ada", "adb": "ada", "ads": "ada",
        "applescript": "applescript", "s": "armasm", "asm": "armasm",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "c": "c", "h": "objectivec", "cc": "cpp", "cp": "cpp",
        "cpp": "cpp", "cxx": "cpp", "hh": "cpp", "hpp": "cpp",
        "cs": "csharp", "css": "css", "scss": "scss", "less": "less",
        "dart": "dart", "diff": "diff", "patch": "diff",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "hrl": "erlang",
        "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp",
        "f": "fortran", "f90": "fortran", "f95": "fortran",
        "go": "go", "groovy": "groovy", "hs": "haskell",
        "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml",
        "ini": "ini", "toml": "ini", "java": "java",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "json": "json", "json5": "json", "kt": "kotlin", "kts": "kotlin",
        "lua": "lua", "md": "markdown", "markdown": "markdown",
        "m": "objectivec", "mm": "objectivec", "ml": "ocaml", "mli": "ocaml",
        "pl": "perl", "pm": "perl", "php": "php", "ps1": "powershell",
        "pro": "prolog", "properties": "properties", "py": "python",
        "r": "r", "rb": "ruby", "rs": "rust", "scala": "scala",
        "scm": "scheme", "sql": "sql", "swift": "swift",
        "ts": "typescript", "tsx": "typescript", "vim": "vim",
        "yaml": "yaml", "yml": "yaml",
    ]

    @objc(languageNameForPath:)
    static func languageName(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        default: break
        }
        return extensionLanguages[(name as NSString).pathExtension]
    }

    @objc(shouldHighlightDiffWithByteCount:)
    static func shouldHighlightDiff(byteCount: UInt) -> Bool {
        byteCount <= maximumHighlightedDiffByteCount
    }

    @objc(highlightedStringForText:path:)
    static func highlightedString(forText text: String, path: String) -> NSAttributedString {
        let language = languageName(forPath: path)
        let attributed = Highlighter.shared.attributedString(
            for: text,
            language: language,
            theme: .xcode
        ).mutableCopy() as! NSMutableAttributedString

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 32
        paragraph.lineBreakMode = .byClipping
        attributed.addAttribute(.paragraphStyle,
                                value: paragraph,
                                range: NSRange(location: 0, length: attributed.length))
        return attributed
    }
}

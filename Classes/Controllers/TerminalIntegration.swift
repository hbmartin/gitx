import AppKit
import CryptoKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

struct TerminalApplication {
    let name: String
    let bundleIdentifier: String

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static let all = [
        TerminalApplication(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
        TerminalApplication(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
        TerminalApplication(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
        TerminalApplication(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable"),
        TerminalApplication(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm"),
        TerminalApplication(name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty"),
        TerminalApplication(name: "Alacritty", bundleIdentifier: "org.alacritty"),
    ]
}

struct TerminalLaunchArgumentPolicy {
    func arguments(identifier: String, directory: String, command: String) -> [String] {
        switch identifier {
        case "com.mitchellh.ghostty":
            ["--working-directory=\(directory)"] + executableArguments(command)
        case "dev.warp.Warp-Stable":
            ["--new-window", "--cwd", directory] + executableArguments(command)
        case "com.github.wez.wezterm":
            ["start", "--cwd", directory, "--always-new-process"] + executableArguments(command)
        case "net.kovidgoyal.kitty":
            ["--directory", directory] + positionalArguments(command)
        case "org.alacritty":
            ["--working-directory", directory] + executableArguments(command)
        default:
            []
        }
    }

    func executableArguments(_ command: String) -> [String] {
        guard !command.isEmpty else { return [] }
        return ["-e", "/bin/zsh", "-lc", command]
    }

    private func positionalArguments(_ command: String) -> [String] {
        guard !command.isEmpty else { return [] }
        return ["/bin/zsh", "-lc", command]
    }
}

@objc(PBTerminalLauncher)
final class TerminalLauncher: NSObject {
    @objc static let shared = TerminalLauncher()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "TerminalLauncher")
    private let launchArgumentPolicy = TerminalLaunchArgumentPolicy()

    @objc(openDirectory:presentingWindow:)
    func open(directory: URL, presenting window: NSWindow?) {
        guard let identifier = configuredIdentifier(presenting: window) else { return }
        do {
            if identifier == "custom" {
                try launchCustom(directory: directory)
                logger.info("Opened terminal for repository")
            } else if identifier == "com.apple.Terminal" || identifier == "com.googlecode.iterm2" {
                ApplicationComposition.shared.applicationPreferences.set(
                    identifier,
                    forKey: "PBTerminalHandler"
                )
                PBTerminalUtil.runCommand(ApplicationSettings.terminalInitialCommand, inDirectory: directory)
                logger.info("Opened terminal for repository")
            } else {
                try launchApplication(identifier: identifier, directory: directory, presenting: window)
            }
        } catch {
            present(error: error, window: window)
        }
    }

    private func configuredIdentifier(presenting window: NSWindow?) -> String? {
        if let identifier = ApplicationSettings.terminalBundleIdentifier, !identifier.isEmpty {
            return identifier
        }
        let available = TerminalApplication.all.filter(\.isInstalled)
        let alert = NSAlert()
        alert.messageText = "Choose a Terminal Application"
        alert.informativeText = "GitX will remember this choice. You can change it later in Settings."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for terminal in available {
            popup.addItem(withTitle: terminal.name)
            popup.lastItem?.representedObject = terminal.bundleIdentifier
        }
        popup.addItem(withTitle: "Custom")
        popup.lastItem?.representedObject = "custom"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let identifier = popup.selectedItem?.representedObject as? String else { return nil }
        ApplicationSettings.terminalBundleIdentifier = identifier
        return identifier
    }

    private func launchApplication(identifier: String, directory: URL, presenting window: NSWindow?) throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            throw TerminalLaunchError.applicationUnavailable(identifier)
        }
        let command = ApplicationSettings.terminalInitialCommand
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        configuration.arguments = launchArguments(
            identifier: identifier,
            directory: directory.path,
            command: command
        )
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                self.completeApplicationLaunch(error: error as NSError?, presenting: window)
            }
        }
    }

    @objc(completeApplicationLaunchWithError:presentingWindow:)
    func completeApplicationLaunch(error: NSError?, presenting window: NSWindow?) {
        if let error {
            logger.error("Terminal launch failed: \(error.localizedDescription, privacy: .public)")
            present(error: error, window: window)
        } else {
            logger.info("Opened terminal for repository")
        }
    }

    @objc(launchArgumentsForIdentifier:directory:command:)
    func launchArguments(identifier: String, directory: String, command: String) -> [String] {
        launchArgumentPolicy.arguments(identifier: identifier, directory: directory, command: command)
    }

    @objc(commandArguments:)
    func commandArguments(_ command: String) -> [String] {
        launchArgumentPolicy.executableArguments(command)
    }

    private func launchCustom(directory: URL) throws {
        let executable = ApplicationSettings.customTerminalExecutable
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw TerminalLaunchError.invalidCustomExecutable
        }
        let command = ApplicationSettings.terminalInitialCommand
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = customArguments(
            template: ApplicationSettings.customTerminalArguments,
            directory: directory.path,
            command: command
        )
        process.currentDirectoryURL = directory
        try process.run()
    }

    @objc(customArgumentsForTemplate:directory:command:)
    func customArguments(template: String, directory: String, command: String) -> [String] {
        argumentTokens(template).map {
            $0.replacingOccurrences(of: "{directory}", with: directory)
                .replacingOccurrences(of: "{command}", with: command)
        }
    }

    @objc(argumentTokens:)
    func argumentTokens(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in string {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if quote != nil {
                if character == quote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func present(error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private enum TerminalLaunchError: LocalizedError {
    case applicationUnavailable(String)
    case invalidCustomExecutable

    var errorDescription: String? {
        switch self {
        case let .applicationUnavailable(identifier):
            "The configured terminal application is not installed (\(identifier))."
        case .invalidCustomExecutable:
            "Choose an absolute path to an executable terminal launcher in Settings."
        }
    }
}

@objc(PBManagedScriptChecksumPolicy)
final nonisolated class ManagedScriptChecksumPolicy: NSObject {
    private static let checksumPrefix = "# GitX checksum: "

    @objc(managedScriptForBody:)
    static func managedScript(for body: String) -> String {
        let canonicalBody = canonicalizingLineEndings(in: body)
        let checksum = SHA256.hash(data: Data(canonicalBody.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let lines = canonicalBody.components(separatedBy: "\n")
        guard !lines.isEmpty else { return canonicalBody }
        return ([lines[0], checksumPrefix + checksum] + lines.dropFirst()).joined(separator: "\n")
    }

    @objc(hasValidChecksumForScript:)
    static func hasValidChecksum(for script: String) -> Bool {
        let canonicalScript = canonicalizingLineEndings(in: script)
        let lines = canonicalScript.components(separatedBy: "\n")
        guard lines.count > 2, lines[1].hasPrefix(checksumPrefix) else { return false }
        let recorded = String(lines[1].dropFirst(checksumPrefix.count))
        let body = ([lines[0]] + lines.dropFirst(2)).joined(separator: "\n")
        let actual = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return recorded == actual
    }

    private static func canonicalizingLineEndings(in string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

@objc(PBRaycastScriptCatalog)
final nonisolated class RaycastScriptCatalog: NSObject {
    struct Script: Sendable {
        let filename: String
        let contents: String
    }

    private static let bundleIdentifier = "net.phere.GitX"
    private static let toolSubpath = "Contents/Resources/gitx"

    /// Raycast commands for a GitX installed at `applicationPath`.
    ///
    /// The scripts must not resolve GitX by bundle identifier alone. Another
    /// bundle on disk can claim net.phere.GitX — Sparkle's embedded Updater.app
    /// did in releases built with a workspace-wide identifier override — and
    /// Spotlight can return that one first. The running app's own path is baked
    /// in, and the Spotlight fallback that keeps the commands working after the
    /// app moves only accepts a bundle that actually contains the gitx tool.
    static func scripts(applicationPath: String) -> [Script] {
        [
            Script(
                filename: "open-repository.sh",
                contents: script(
                    title: "Open Repository Path in GitX",
                    metadata: ["# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"Repository path\" }"],
                    applicationPath: applicationPath,
                    body: "\"$APP/\(toolSubpath)\" \"$1\""
                )
            ),
            Script(
                filename: "open-finder.sh",
                contents: script(
                    title: "Open Frontmost Finder Folder in GitX",
                    applicationPath: applicationPath,
                    body: """
                    DIR=$(osascript -e 'tell application "Finder" to POSIX path of (target of front window as alias)') || exit 1
                    [ -n "$DIR" ] || exit 1
                    "$APP/\(toolSubpath)" "$DIR"
                    """
                )
            ),
            Script(
                filename: "show-recents.sh",
                contents: script(
                    title: "Show GitX Recents",
                    applicationPath: applicationPath,
                    body: "open -a \"$APP\" --args --welcome"
                )
            ),
            Script(
                filename: "start-clone.sh",
                contents: script(
                    title: "Start GitX Clone",
                    applicationPath: applicationPath,
                    body: "open -a \"$APP\" --args --clone"
                )
            ),
        ]
    }

    @objc(scriptContentsForApplicationPath:)
    // swiftlint:disable:next unused_declaration
    static func scriptContents(forApplicationPath applicationPath: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: scripts(applicationPath: applicationPath)
                .map { ($0.filename, $0.contents) }
        )
    }

    /// Wraps a value in single quotes so the shell reads it literally, however
    /// many spaces, quotes, or expansions it contains.
    @objc(shellQuotedValue:)
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func script(
        title: String,
        metadata: [String] = [],
        applicationPath: String,
        body: String
    ) -> String {
        let lines = [
            "#!/bin/zsh",
            "# GitX managed Raycast command v2",
            "# @raycast.schemaVersion 1",
            "# @raycast.mode silent",
            "# @raycast.title \(title)",
        ] + metadata + [resolveApplication(path: applicationPath), body]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func resolveApplication(path: String) -> String {
        """
        APP=\(shellQuoted(path))
        if [ ! -x "$APP/\(toolSubpath)" ]; then
          APP=$(mdfind "kMDItemCFBundleIdentifier == '\(bundleIdentifier)'" | while IFS= read -r candidate; do
            [ -x "$candidate/\(toolSubpath)" ] || continue
            printf '%s\\n' "$candidate"
            break
          done)
        fi
        if [ ! -x "$APP/\(toolSubpath)" ]; then
          echo "The embedded GitX command-line tool could not be found or is not executable. Reinstall the Raycast commands from GitX Settings." >&2
          exit 1
        fi
        """
    }
}

@objc(PBIntegrationManager)
final class IntegrationManager: NSObject {
    @objc static let shared = IntegrationManager()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "Integration")
    private let managedPrefix = "gitx-raycast-"

    @objc func installRaycastScripts(presenting window: NSWindow?) {
        guard let directory = scriptsDirectory(presenting: window) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for script in raycastScripts {
                let destination = directory.appendingPathComponent(managedPrefix + script.filename)
                if FileManager.default.fileExists(atPath: destination.path),
                   let existing = try? String(contentsOf: destination, encoding: .utf8),
                   existing != script.contents,
                   !ManagedScriptChecksumPolicy.hasValidChecksum(for: existing)
                {
                    let alert = NSAlert()
                    alert.messageText = "Replace Modified Raycast Script?"
                    alert.informativeText = destination.lastPathComponent
                    alert.addButton(withTitle: "Replace Modified")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                try script.contents.write(to: destination, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
            logger.info("Installed managed Raycast commands")
            present(title: "Raycast Commands Installed", message: "Four GitX commands are ready in Raycast.", window: window)
        } catch {
            present(error: error, window: window)
        }
    }

    @objc func removeRaycastScripts(presenting window: NSWindow?) {
        guard let directory = scriptsDirectory(presenting: window, promptIfMissing: false) else { return }
        do {
            var removedCount = 0
            var preservedCount = 0
            for script in raycastScripts {
                let file = directory.appendingPathComponent(managedPrefix + script.filename)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard let contents = try? String(contentsOf: file, encoding: .utf8),
                      ManagedScriptChecksumPolicy.hasValidChecksum(for: contents)
                else {
                    preservedCount += 1
                    logger.notice("Preserved a modified managed Raycast command")
                    continue
                }
                try FileManager.default.removeItem(at: file)
                removedCount += 1
            }
            logger.info("Removed \(removedCount) managed Raycast command(s); preserved \(preservedCount)")
            present(
                title: "Raycast Commands Removed",
                message: preservedCount == 0
                    ? "GitX left other scripts unchanged."
                    : "GitX preserved modified and user-authored scripts.",
                window: window
            )
        } catch {
            present(error: error, window: window)
        }
    }

    private func scriptsDirectory(presenting window: NSWindow?, promptIfMissing: Bool = true) -> URL? {
        if !ApplicationSettings.raycastScriptsDirectory.isEmpty {
            return URL(fileURLWithPath: ApplicationSettings.raycastScriptsDirectory, isDirectory: true)
        }
        guard promptIfMissing else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        let response = window.map { _ in panel.runModal() } ?? panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        ApplicationSettings.raycastScriptsDirectory = url.path
        return url
    }

    private var raycastScripts: [(filename: String, contents: String)] {
        RaycastScriptCatalog.scripts(applicationPath: Bundle.main.bundlePath)
            .map { ($0.filename, ManagedScriptChecksumPolicy.managedScript(for: $0.contents)) }
    }

    private func present(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func present(error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

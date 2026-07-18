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

@objc(PBTerminalLauncher)
final class TerminalLauncher: NSObject {
    @objc static let shared = TerminalLauncher()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "TerminalLauncher")

    @objc(openDirectory:presentingWindow:)
    func open(directory: URL, presenting window: NSWindow?) {
        guard let identifier = configuredIdentifier(presenting: window) else { return }
        do {
            if identifier == "custom" {
                try launchCustom(directory: directory)
            } else if identifier == "com.apple.Terminal" || identifier == "com.googlecode.iterm2" {
                ApplicationComposition.shared.applicationPreferences.set(
                    identifier,
                    forKey: "PBTerminalHandler"
                )
                PBTerminalUtil.runCommand(ApplicationSettings.terminalInitialCommand, inDirectory: directory)
            } else {
                try launchApplication(identifier: identifier, directory: directory)
            }
            logger.info("Opened terminal for repository")
        } catch {
            let alert = NSAlert(error: error)
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
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

    private func launchApplication(identifier: String, directory: URL) throws {
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
            if let error {
                self.logger.error("Terminal launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc(launchArgumentsForIdentifier:directory:command:)
    func launchArguments(identifier: String, directory: String, command: String) -> [String] {
        switch identifier {
        case "com.mitchellh.ghostty":
            ["--working-directory=\(directory)"] + commandArguments(command)
        case "dev.warp.Warp-Stable":
            ["--new-window", "--cwd", directory] + commandArguments(command)
        case "com.github.wez.wezterm":
            ["start", "--cwd", directory, "--always-new-process"] + commandArguments(command)
        case "net.kovidgoyal.kitty":
            ["--directory", directory] + commandArguments(command)
        case "org.alacritty":
            ["--working-directory", directory] + commandArguments(command)
        default:
            []
        }
    }

    @objc(commandArguments:)
    func commandArguments(_ command: String) -> [String] {
        guard !command.isEmpty else { return [] }
        return ["-e", "/bin/zsh", "-lc", command]
    }

    private func launchCustom(directory: URL) throws {
        let executable = ApplicationSettings.customTerminalExecutable
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw TerminalLaunchError.invalidCustomExecutable
        }
        let command = ApplicationSettings.terminalInitialCommand
        let replaced = ApplicationSettings.customTerminalArguments
            .replacingOccurrences(of: "{directory}", with: directory.path)
            .replacingOccurrences(of: "{command}", with: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argumentTokens(replaced)
        process.currentDirectoryURL = directory
        try process.run()
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
                   !hasValidManagedChecksum(existing)
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
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix(managedPrefix) {
                try FileManager.default.removeItem(at: file)
            }
            logger.info("Removed managed Raycast commands")
            present(title: "Raycast Commands Removed", message: "GitX left other scripts unchanged.", window: window)
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
        let appLookup = "APP=$(mdfind \\\"kMDItemCFBundleIdentifier == 'net.phere.GitX'\\\" | head -1)"
        let header = "#!/bin/zsh\n# GitX managed Raycast command v1\n# @raycast.schemaVersion 1\n# @raycast.mode silent\n"
        return [
            ("open-repository.sh", header + "# @raycast.title Open Repository Path in GitX\n# @raycast.argument1 { \\\"type\\\": \\\"text\\\", \\\"placeholder\\\": \\\"Repository path\\\" }\n\(appLookup)\n\\\"$APP/Contents/Resources/gitx\\\" \\\"$1\\\"\n"),
            ("open-finder.sh", header + "# @raycast.title Open Frontmost Finder Folder in GitX\n\(appLookup)\nDIR=$(osascript -e 'tell application \\\"Finder\\\" to POSIX path of (target of front window as alias)')\n\\\"$APP/Contents/Resources/gitx\\\" \\\"$DIR\\\"\n"),
            ("show-recents.sh", header + "# @raycast.title Show GitX Recents\nopen -b net.phere.GitX --args --welcome\n"),
            ("start-clone.sh", header + "# @raycast.title Start GitX Clone\nopen -b net.phere.GitX --args --clone\n"),
        ].map { ($0.0, managedScript($0.1)) }
    }

    private func managedScript(_ body: String) -> String {
        let checksum = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        let lines = body.components(separatedBy: "\n")
        guard !lines.isEmpty else { return body }
        return ([lines[0], "# GitX checksum: \(checksum)"] + lines.dropFirst()).joined(separator: "\n")
    }

    private func hasValidManagedChecksum(_ script: String) -> Bool {
        let lines = script.components(separatedBy: "\n")
        guard lines.count > 2, lines[1].hasPrefix("# GitX checksum: ") else { return false }
        let recorded = String(lines[1].dropFirst("# GitX checksum: ".count))
        let body = ([lines[0]] + lines.dropFirst(2)).joined(separator: "\n")
        let actual = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        return recorded == actual
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

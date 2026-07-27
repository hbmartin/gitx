import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// Row cell for the staging file lists: staging checkbox, status icon, path,
/// and a trailing overflow button that pops the row's context menu.
@objc(PBStagingFileCellView)
final class StagingFileCellView: NSTableCellView {
    @objc let checkbox: NSButton
    @objc let pathField: NSTextField
    @objc let iconView: NSImageView
    @objc let overflowButton: NSButton

    override init(frame frameRect: NSRect) {
        checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.allowsMixedState = true
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        pathField = NSTextField(labelWithString: "")
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        overflowButton = NSButton(title: "…", target: nil, action: nil)
        overflowButton.isBordered = false
        overflowButton.setContentHuggingPriority(.required, for: .horizontal)
        overflowButton.toolTip = NSLocalizedString(
            "File actions",
            comment: "Tooltip of the per-row overflow menu button in the staging file list"
        )

        super.init(frame: frameRect)

        let stack = NSStackView(views: [checkbox, iconView, pathField, overflowButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
        textField = pathField
        imageView = iconView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StagingFileCellView is built in code")
    }

    @objc(configureWithFile:checkboxState:)
    func configure(with file: PBChangedFile, checkboxState: Int) {
        pathField.stringValue = file.path
        pathField.toolTip = file.path
        iconView.image = file.icon()
        checkbox.state = NSControl.StateValue(rawValue: checkboxState)
        checkbox.setAccessibilityLabel(String(
            format: NSLocalizedString(
                "Toggle staging for %@",
                comment: "Accessibility label for a staging checkbox, including the file path"
            ),
            file.path
        ))
        overflowButton.setAccessibilityLabel(String(
            format: NSLocalizedString(
                "File actions for %@",
                comment: "Accessibility label for a staging file action button, including the file path"
            ),
            file.path
        ))
    }
}

/// Section header ("Staged files" / "Unstaged files") with a master checkbox
/// that stages or unstages the whole section.
@objc(PBStagingSectionHeaderView)
final class StagingSectionHeaderView: NSView {
    @objc let masterCheckbox: NSButton
    @objc let titleField: NSTextField

    override init(frame frameRect: NSRect) {
        masterCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        masterCheckbox.allowsMixedState = true
        titleField = NSTextField(labelWithString: "")
        titleField.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        super.init(frame: frameRect)

        let stack = NSStackView(views: [masterCheckbox, titleField])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StagingSectionHeaderView is built in code")
    }

    @objc(configureWithTitle:fileCount:masterState:)
    func configure(title: String, fileCount: Int, masterState: Int) {
        titleField.stringValue = fileCount > 0 ? "\(title) (\(fileCount))" : title
        masterCheckbox.state = NSControl.StateValue(rawValue: masterState)
        masterCheckbox.isEnabled = fileCount > 0
        masterCheckbox.setAccessibilityLabel(String(
            format: NSLocalizedString(
                "Toggle %@",
                comment: "Accessibility label for a staging section checkbox, including the section title"
            ),
            title
        ))
    }
}

// swiftlint:enable unused_declaration

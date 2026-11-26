import AppKit
import UniformTypeIdentifiers

/// GUI permission editor ("Change Attributes / chmod") for files and folders.
/// Provides a clear graphical matrix of checkboxes:
/// - Read, Write, Execute
/// - Owner (User), Group, Others
/// - Special flags: SetUID, SetGID, Sticky
/// - Octal display (e.g. 0755) and symbolic string (e.g. -rwxr-xr-x)
/// - Recursive option for folders
public final class ChmodDialogController: NSWindowController {
    public struct PermissionState {
        public var ownerRead: Bool
        public var ownerWrite: Bool
        public var ownerExecute: Bool

        public var groupRead: Bool
        public var groupWrite: Bool
        public var groupExecute: Bool

        public var otherRead: Bool
        public var otherWrite: Bool
        public var otherExecute: Bool

        public var setUID: Bool
        public var setGID: Bool
        public var sticky: Bool

        public var recursive: Bool

        public init(mode: Int = 0o755, recursive: Bool = false) {
            self.ownerRead = (mode & 0o400) != 0
            self.ownerWrite = (mode & 0o200) != 0
            self.ownerExecute = (mode & 0o100) != 0

            self.groupRead = (mode & 0o040) != 0
            self.groupWrite = (mode & 0o020) != 0
            self.groupExecute = (mode & 0o010) != 0

            self.otherRead = (mode & 0o004) != 0
            self.otherWrite = (mode & 0o002) != 0
            self.otherExecute = (mode & 0o001) != 0

            self.setUID = (mode & 0o4000) != 0
            self.setGID = (mode & 0o2000) != 0
            self.sticky = (mode & 0o1000) != 0

            self.recursive = recursive
        }

        public var mode: Int {
            var m = 0
            if setUID { m |= 0o4000 }
            if setGID { m |= 0o2000 }
            if sticky { m |= 0o1000 }

            if ownerRead { m |= 0o400 }
            if ownerWrite { m |= 0o200 }
            if ownerExecute { m |= 0o100 }

            if groupRead { m |= 0o040 }
            if groupWrite { m |= 0o020 }
            if groupExecute { m |= 0o010 }

            if otherRead { m |= 0o004 }
            if otherWrite { m |= 0o002 }
            if otherExecute { m |= 0o001 }
            return m
        }

        public var octalString: String {
            String(format: "%04o", mode)
        }

        public var symbolicString: String {
            var s = ""
            s += ownerRead ? "r" : "-"
            s += ownerWrite ? "w" : "-"
            if setUID {
                s += ownerExecute ? "s" : "S"
            } else {
                s += ownerExecute ? "x" : "-"
            }

            s += groupRead ? "r" : "-"
            s += groupWrite ? "w" : "-"
            if setGID {
                s += groupExecute ? "s" : "S"
            } else {
                s += groupExecute ? "x" : "-"
            }

            s += otherRead ? "r" : "-"
            s += otherWrite ? "w" : "-"
            if sticky {
                s += otherExecute ? "t" : "T"
            } else {
                s += otherExecute ? "x" : "-"
            }
            return s
        }
    }

    public let targets: [FileEntry]
    public private(set) var state: PermissionState
    private let onApply: (PermissionState) -> Void

    // UI Controls
    private let octalLabel = NSTextField(labelWithString: "0755")
    private let symbolicLabel = NSTextField(labelWithString: "-rwxr-xr-x")

    // Checkboxes
    public let cbOwnerRead = NSButton(checkboxWithTitle: "Read (r)", target: nil, action: nil)
    public let cbOwnerWrite = NSButton(checkboxWithTitle: "Write (w)", target: nil, action: nil)
    public let cbOwnerExec = NSButton(checkboxWithTitle: "Execute (x)", target: nil, action: nil)

    public let cbGroupRead = NSButton(checkboxWithTitle: "Read (r)", target: nil, action: nil)
    public let cbGroupWrite = NSButton(checkboxWithTitle: "Write (w)", target: nil, action: nil)
    public let cbGroupExec = NSButton(checkboxWithTitle: "Execute (x)", target: nil, action: nil)

    public let cbOtherRead = NSButton(checkboxWithTitle: "Read (r)", target: nil, action: nil)
    public let cbOtherWrite = NSButton(checkboxWithTitle: "Write (w)", target: nil, action: nil)
    public let cbOtherExec = NSButton(checkboxWithTitle: "Execute (x)", target: nil, action: nil)

    public let cbSetUID = NSButton(checkboxWithTitle: "SetUID (s)", target: nil, action: nil)
    public let cbSetGID = NSButton(checkboxWithTitle: "SetGID (s)", target: nil, action: nil)
    public let cbSticky = NSButton(checkboxWithTitle: "Sticky bit (t)", target: nil, action: nil)

    public let cbRecursive = NSButton(checkboxWithTitle: "Include subfolders and files (recursive)", target: nil, action: nil)

    public init(targets: [FileEntry], initialMode: Int? = nil, onApply: @escaping (PermissionState) -> Void) {
        self.targets = targets
        self.onApply = onApply
        let mode = initialMode ?? targets.first?.permissions ?? 0o755
        self.state = PermissionState(mode: mode)

        let hasDir = targets.contains { $0.kind == .directory }
        let winHeight: CGFloat = hasDir ? 345 : 315
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: winHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = AppWindows.title("Change Attributes / Permissions")
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        syncStateToUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        guard let window = window else { return }
        AppWindows.place(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSView {
        // Top Target Header with File Icon
        let first = targets.first
        let ext = first.map { ($0.name as NSString).pathExtension.lowercased() } ?? ""
        let icon: NSImage
        if targets.count == 1, let t = first {
            if t.kind == .directory {
                icon = NSWorkspace.shared.icon(for: .folder)
            } else {
                let ut = UTType(filenameExtension: ext) ?? .data
                icon = NSWorkspace.shared.icon(for: ut)
            }
        } else {
            icon = NSWorkspace.shared.icon(for: .folder)
        }
        icon.size = NSSize(width: 36, height: 36)
        let iconView = NSImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let heading = NSTextField(labelWithString: "Change Permissions")
        heading.font = .systemFont(ofSize: 13, weight: .bold)

        let targetDesc: String
        if targets.count == 1 {
            targetDesc = targets[0].name
        } else {
            targetDesc = "\(targets.count) selected items"
        }
        let targetLabel = NSTextField(labelWithString: targetDesc)
        targetLabel.font = .systemFont(ofSize: 12)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.toolTip = targetDesc

        let headerText = NSStackView(views: [heading, targetLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2

        // Live Octal & Symbolic Display Pill
        octalLabel.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        octalLabel.textColor = .labelColor
        symbolicLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        symbolicLabel.textColor = .secondaryLabelColor

        let badgeStack = NSStackView(views: [octalLabel, symbolicLabel])
        badgeStack.spacing = 8
        badgeStack.alignment = .centerY

        let topRow = NSStackView(views: [iconView, headerText, NSView(), badgeStack])
        topRow.alignment = .centerY
        topRow.spacing = 10

        // Helper to build a clean card view with subtle native styling
        func makeCard(views: [NSView]) -> NSBox {
            let box = NSBox()
            box.boxType = .custom
            box.isTransparent = false
            box.borderWidth = 1
            box.cornerRadius = 7
            box.borderColor = NSColor.separatorColor.withAlphaComponent(0.7)
            box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.2)

            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            stack.translatesAutoresizingMaskIntoConstraints = false

            box.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                stack.topAnchor.constraint(equalTo: box.topAnchor),
                stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            return box
        }

        // Section 1: Clean Permission Matrix Table
        func makeHeaderLabel(_ text: String) -> NSTextField {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: 10, weight: .bold)
            lbl.textColor = .secondaryLabelColor
            return lbl
        }

        func makeRowLabel(_ text: String) -> NSTextField {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = .labelColor
            return lbl
        }

        let headerPerm = makeHeaderLabel("PERMISSION")
        let headerOwner = makeHeaderLabel("OWNER (u)")
        let headerGroup = makeHeaderLabel("GROUP (g)")
        let headerOthers = makeHeaderLabel("OTHERS (o)")
        let headerSpecial = makeHeaderLabel("SPECIAL")

        let lblRead = makeRowLabel("Read (r)")
        let lblWrite = makeRowLabel("Write (w)")
        let lblExec = makeRowLabel("Execute (x)")

        // Configure matrix checkboxes (title cleared so checkmark centers under column)
        let matrixBoxes = [
            (cbOwnerRead, "Owner Read"), (cbOwnerWrite, "Owner Write"), (cbOwnerExec, "Owner Execute"),
            (cbGroupRead, "Group Read"), (cbGroupWrite, "Group Write"), (cbGroupExec, "Group Execute"),
            (cbOtherRead, "Others Read"), (cbOtherWrite, "Others Write"), (cbOtherExec, "Others Execute"),
        ]
        for (b, accLabel) in matrixBoxes {
            b.title = ""
            b.target = self
            b.action = #selector(checkboxChanged)
            b.setAccessibilityLabel(accLabel)
        }

        cbSetUID.title = "SetUID (s)"
        cbSetGID.title = "SetGID (s)"
        cbSticky.title = "Sticky bit (t)"
        for b in [cbSetUID, cbSetGID, cbSticky] {
            b.target = self
            b.action = #selector(checkboxChanged)
            b.font = .systemFont(ofSize: 11)
        }

        let matrixGrid = NSGridView(views: [
            [headerPerm, headerOwner, headerGroup, headerOthers, headerSpecial],
            [lblRead, cbOwnerRead, cbGroupRead, cbOtherRead, cbSetUID],
            [lblWrite, cbOwnerWrite, cbGroupWrite, cbOtherWrite, cbSetGID],
            [lblExec, cbOwnerExec, cbGroupExec, cbOtherExec, cbSticky],
        ])
        matrixGrid.rowSpacing = 8
        matrixGrid.columnSpacing = 16
        matrixGrid.column(at: 0).xPlacement = .leading
        matrixGrid.column(at: 1).xPlacement = .center
        matrixGrid.column(at: 2).xPlacement = .center
        matrixGrid.column(at: 3).xPlacement = .center
        matrixGrid.column(at: 4).xPlacement = .leading
        matrixGrid.translatesAutoresizingMaskIntoConstraints = false

        cbRecursive.target = self
        cbRecursive.action = #selector(checkboxChanged)
        cbRecursive.font = .systemFont(ofSize: 11)
        cbRecursive.title = "Apply recursively to enclosed files and folders"
        let hasFolder = targets.contains { $0.kind == .directory }
        cbRecursive.isHidden = !hasFolder

        var matrixElements: [NSView] = [matrixGrid]
        let sep: NSBox?
        if hasFolder {
            let s = NSBox()
            s.boxType = .separator
            s.translatesAutoresizingMaskIntoConstraints = false
            matrixElements.append(s)
            matrixElements.append(cbRecursive)
            sep = s
        } else {
            sep = nil
        }
        let matrixCard = makeCard(views: matrixElements)
        if let sep = sep {
            sep.widthAnchor.constraint(equalTo: matrixCard.widthAnchor, constant: -28).isActive = true
        }

        // Section 2: Balanced Presets Grid
        let presetsTitle = makeHeaderLabel("PRESETS")

        func makePresetButton(title: String, toolTip: String, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .regularSquare
            b.font = .systemFont(ofSize: 11)
            b.toolTip = toolTip
            return b
        }

        let p644 = makePresetButton(title: "644 (Standard File)",
                                    toolTip: "Owner can edit; everyone else can view. Safest default for files.",
                                    action: #selector(preset644Pressed))
        let p755 = makePresetButton(title: "755 (Folder / Script)",
                                    toolTip: "Owner can read/write/enter; everyone else can view and execute.",
                                    action: #selector(preset755Pressed))
        let p600 = makePresetButton(title: "600 (SSH Key)",
                                    toolTip: "Only owner can read & write. Required for SSH keys.",
                                    action: #selector(preset600Pressed))

        let p444 = makePresetButton(title: "444 (Read-Only)",
                                    toolTip: "Strictly read-only for everyone. Prevents accidental edits.",
                                    action: #selector(preset444Pressed))
        let p777 = makePresetButton(title: "777 (Full Access)",
                                    toolTip: "Full read, write, and execute for everyone.",
                                    action: #selector(preset777Pressed))
        let p000 = makePresetButton(title: "000 (No Access)",
                                    toolTip: "Zero permissions for everybody.",
                                    action: #selector(preset000Pressed))

        let presetsRow1 = NSStackView(views: [p644, p755, p600])
        presetsRow1.distribution = .fillEqually
        presetsRow1.spacing = 8
        presetsRow1.translatesAutoresizingMaskIntoConstraints = false

        let presetsRow2 = NSStackView(views: [p444, p777, p000])
        presetsRow2.distribution = .fillEqually
        presetsRow2.spacing = 8
        presetsRow2.translatesAutoresizingMaskIntoConstraints = false

        let presetsCard = makeCard(views: [presetsTitle, presetsRow1, presetsRow2])
        NSLayoutConstraint.activate([
            presetsRow1.widthAnchor.constraint(equalTo: presetsCard.widthAnchor, constant: -28),
            presetsRow2.widthAnchor.constraint(equalTo: presetsCard.widthAnchor, constant: -28),
        ])

        // Section 3: Bottom Action Buttons
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyPressed))
        applyButton.bezelStyle = .regularSquare
        applyButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .regularSquare
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let mainStack = NSStackView(views: [
            topRow,
            matrixCard,
            presetsCard,
            buttonRow
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -28),
            matrixCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -28),
            presetsCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -28),
            buttonRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -28),
        ])
        return root
    }

    private func syncStateToUI() {
        cbOwnerRead.state = state.ownerRead ? .on : .off
        cbOwnerWrite.state = state.ownerWrite ? .on : .off
        cbOwnerExec.state = state.ownerExecute ? .on : .off

        cbGroupRead.state = state.groupRead ? .on : .off
        cbGroupWrite.state = state.groupWrite ? .on : .off
        cbGroupExec.state = state.groupExecute ? .on : .off

        cbOtherRead.state = state.otherRead ? .on : .off
        cbOtherWrite.state = state.otherWrite ? .on : .off
        cbOtherExec.state = state.otherExecute ? .on : .off

        cbSetUID.state = state.setUID ? .on : .off
        cbSetGID.state = state.setGID ? .on : .off
        cbSticky.state = state.sticky ? .on : .off

        cbRecursive.state = state.recursive ? .on : .off

        octalLabel.stringValue = state.octalString
        symbolicLabel.stringValue = state.symbolicString
    }

    @objc private func checkboxChanged() {
        state.ownerRead = cbOwnerRead.state == .on
        state.ownerWrite = cbOwnerWrite.state == .on
        state.ownerExecute = cbOwnerExec.state == .on

        state.groupRead = cbGroupRead.state == .on
        state.groupWrite = cbGroupWrite.state == .on
        state.groupExecute = cbGroupExec.state == .on

        state.otherRead = cbOtherRead.state == .on
        state.otherWrite = cbOtherWrite.state == .on
        state.otherExecute = cbOtherExec.state == .on

        state.setUID = cbSetUID.state == .on
        state.setGID = cbSetGID.state == .on
        state.sticky = cbSticky.state == .on

        state.recursive = cbRecursive.state == .on

        octalLabel.stringValue = state.octalString
        symbolicLabel.stringValue = state.symbolicString
    }

    @objc private func preset755Pressed() {
        state = PermissionState(mode: 0o755, recursive: cbRecursive.state == .on)
        syncStateToUI()
    }

    @objc private func preset644Pressed() {
        state = PermissionState(mode: 0o644, recursive: cbRecursive.state == .on)
        syncStateToUI()
    }

    @objc private func preset600Pressed() {
        state = PermissionState(mode: 0o600, recursive: cbRecursive.state == .on)
        syncStateToUI()
    }

    @objc private func preset444Pressed() {
        state = PermissionState(mode: 0o444, recursive: cbRecursive.state == .on)
        syncStateToUI()
    }

    @objc private func preset777Pressed() {
        state = PermissionState(mode: 0o777, recursive: cbRecursive.state == .on)
        syncStateToUI()
    }

    @objc private func preset000Pressed() {
        state = PermissionState(mode: 0o000, recursive: cbRecursive.state == .on)
        syncStateToUI()
    }

    @objc private func applyPressed() {
        onApply(state)
        close()
    }

    @objc private func cancelPressed() {
        close()
    }
}

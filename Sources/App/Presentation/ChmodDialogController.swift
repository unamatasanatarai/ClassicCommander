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
            let flags: [(Bool, Int)] = [
                (setUID, 0o4000), (setGID, 0o2000), (sticky, 0o1000),
                (ownerRead, 0o400), (ownerWrite, 0o200), (ownerExecute, 0o100),
                (groupRead, 0o040), (groupWrite, 0o020), (groupExecute, 0o010),
                (otherRead, 0o004), (otherWrite, 0o002), (otherExecute, 0o001),
            ]
            return flags.reduce(0) { $1.0 ? ($0 | $1.1) : $0 }
        }

        public var octalString: String {
            String(format: "%04o", mode)
        }

        public var symbolicString: String {
            triad(ownerRead, ownerWrite, ownerExecute, special: setUID, lower: "s", upper: "S")
                + triad(groupRead, groupWrite, groupExecute, special: setGID, lower: "s", upper: "S")
                + triad(otherRead, otherWrite, otherExecute, special: sticky, lower: "t", upper: "T")
        }

        private func triad(_ r: Bool, _ w: Bool, _ x: Bool, special: Bool, lower: String, upper: String) -> String {
            let exec = special ? (x ? lower : upper) : (x ? "x" : "-")
            return Self.rwxChar(r, "r") + Self.rwxChar(w, "w") + exec
        }

        private static func rwxChar(_ on: Bool, _ ch: String) -> String { on ? ch : "-" }
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

    private var presetChips: [(mode: Int, button: NSButton, title: String, sub: String)] = []

    public init(targets: [FileEntry], initialMode: Int? = nil, onApply: @escaping (PermissionState) -> Void) {
        self.targets = targets
        self.onApply = onApply
        let mode = initialMode ?? targets.first?.permissions ?? 0o755
        self.state = PermissionState(mode: mode)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = AppWindows.title("Change permissions")
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        window.backgroundColor = isDark
            ? NSColor(srgbRed: 36/255, green: 36/255, blue: 38/255, alpha: 1)
            : NSColor(srgbRed: 244/255, green: 244/255, blue: 244/255, alpha: 1)
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

    private func makeHeaderRow() -> NSStackView {
        let heading = NSTextField(labelWithString: "Permissions")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let targetDesc = targets.count == 1 ? targets[0].name : "\(targets.count) selected items"
        let targetLabel = NSTextField(labelWithString: targetDesc)
        targetLabel.font = .systemFont(ofSize: 14)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.toolTip = targetDesc
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerText = NSStackView(views: [heading, targetLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2

        octalLabel.font = .monospacedSystemFont(ofSize: 26, weight: .bold)
        octalLabel.textColor = .labelColor
        octalLabel.setContentHuggingPriority(.required, for: .horizontal)
        symbolicLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        symbolicLabel.textColor = .secondaryLabelColor
        symbolicLabel.setContentHuggingPriority(.required, for: .horizontal)

        let badgeStack = NSStackView(views: [octalLabel, symbolicLabel])
        badgeStack.spacing = 12
        badgeStack.alignment = .firstBaseline

        let topRow = NSStackView(views: [headerText, NSView(), badgeStack])
        topRow.alignment = .bottom
        topRow.spacing = 16
        return topRow
    }

    private func makeColHeader(_ text: String, align: NSTextAlignment = .center) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        lbl.alignment = align
        return lbl
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 14)
        lbl.textColor = .labelColor
        return lbl
    }

    private func configureMatrixBoxes() {
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
    }

    private func makeMatrixCard(isDark: Bool) -> NSBox {
        let card = NSBox()
        card.boxType = .custom
        card.borderWidth = 1
        card.cornerRadius = 10
        card.borderColor = isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(srgbRed: 214/255, green: 214/255, blue: 214/255, alpha: 1)
        card.fillColor = isDark ? NSColor(white: 0.18, alpha: 1) : .white
        return card
    }

    private func build() -> NSView {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let topRow = makeHeaderRow()
        configureMatrixBoxes()
        let matrixCard = makeMatrixCard(isDark: isDark)

        let matrixGrid = NSGridView(views: [
            [NSGridCell.emptyContentView, makeColHeader("Owner"), makeColHeader("Group"), makeColHeader("Others")],
            [makeRowLabel("Read (r)"), cbOwnerRead, cbGroupRead, cbOtherRead],
            [makeRowLabel("Write (w)"), cbOwnerWrite, cbGroupWrite, cbOtherWrite],
            [makeRowLabel("Execute (x)"), cbOwnerExec, cbGroupExec, cbOtherExec],
        ])
        matrixGrid.rowSpacing = 12
        matrixGrid.columnSpacing = 12
        matrixGrid.column(at: 0).xPlacement = .leading
        matrixGrid.column(at: 1).xPlacement = .center
        matrixGrid.column(at: 2).xPlacement = .center
        matrixGrid.column(at: 3).xPlacement = .center
        matrixGrid.translatesAutoresizingMaskIntoConstraints = false
        matrixCard.addSubview(matrixGrid)
        NSLayoutConstraint.activate([
            matrixGrid.leadingAnchor.constraint(equalTo: matrixCard.leadingAnchor, constant: 16),
            matrixGrid.trailingAnchor.constraint(equalTo: matrixCard.trailingAnchor, constant: -16),
            matrixGrid.topAnchor.constraint(equalTo: matrixCard.topAnchor, constant: 12),
            matrixGrid.bottomAnchor.constraint(equalTo: matrixCard.bottomAnchor, constant: -12),
        ])

        cbSetUID.title = "SetUID (s)"
        cbSetGID.title = "SetGID (s)"
        cbSticky.title = "Sticky bit (t)"
        for b in [cbSetUID, cbSetGID, cbSticky] {
            b.target = self
            b.action = #selector(checkboxChanged)
            b.font = .systemFont(ofSize: 14)
        }
        let specialHeading = makeColHeader("Special", align: .left)
        specialHeading.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let specialRow = NSStackView(views: [specialHeading, cbSetUID, cbSetGID, cbSticky, NSView()])
        specialRow.spacing = 18
        specialRow.alignment = .centerY

        cbRecursive.target = self
        cbRecursive.action = #selector(checkboxChanged)
        cbRecursive.title = "Include subfolders and files (recursive)"
        let hasFolder = targets.contains { $0.kind == .directory }
        cbRecursive.isHidden = !hasFolder

        let presetsTitle = makeColHeader("Presets", align: .left)
        func makeChip(_ mode: Int, _ title: String, _ sub: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: "\(title) \(sub)", target: self, action: action)
            b.bezelStyle = .rounded
            b.toolTip = tip
            presetChips.append((mode, b, title, sub))
            return b
        }

        let p644 = makeChip(0o644, "644", "Files", "Owner can edit; everyone else can view.", #selector(preset644Pressed))
        let p755 = makeChip(0o755, "755", "Programs", "Owner can edit/enter; everyone else can view and execute.", #selector(preset755Pressed))
        let p600 = makeChip(0o600, "600", "Private", "Only owner can read & write.", #selector(preset600Pressed))
        let p444 = makeChip(0o444, "444", "Read-only", "Strictly read-only for everyone.", #selector(preset444Pressed))
        let p777 = makeChip(0o777, "777", "Everyone", "Full read, write, and execute for everyone.", #selector(preset777Pressed))
        let p000 = makeChip(0o000, "000", "None", "Zero permissions for everybody.", #selector(preset000Pressed))

        let chipsRow1 = NSStackView(views: [p644, p755, p600, p444, p777, p000])
        chipsRow1.spacing = 8
        chipsRow1.distribution = .fillProportionally
        let presetsStack = NSStackView(views: [presetsTitle, chipsRow1])
        presetsStack.orientation = .vertical
        presetsStack.alignment = .leading
        presetsStack.spacing = 8

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyPressed))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.bezelColor = AppWindows.accent
        applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true

        let buttonRow = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY

        var views: [NSView] = [topRow, matrixCard, specialRow]
        if hasFolder { views.append(cbRecursive) }
        views.append(contentsOf: [presetsStack, buttonRow])

        let m: CGFloat = 24
        let mainStack = NSStackView(views: views)
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 18
        mainStack.edgeInsets = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 600),
            topRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -m * 2),
            matrixCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -m * 2),
            specialRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -m * 2),
            presetsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -m * 2),
            buttonRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -m * 2),
        ])

        if let window = window {
            AppWindows.setTabOrder([
                cbOwnerRead, cbGroupRead, cbOtherRead,
                cbOwnerWrite, cbGroupWrite, cbOtherWrite,
                cbOwnerExec, cbGroupExec, cbOtherExec,
                cbSetUID, cbSetGID, cbSticky,
                cancelButton, applyButton
            ], in: window)
        }
        return root
    }

    private func syncStateToUI() {
        let pairs: [(NSButton, Bool)] = [
            (cbOwnerRead, state.ownerRead), (cbOwnerWrite, state.ownerWrite), (cbOwnerExec, state.ownerExecute),
            (cbGroupRead, state.groupRead), (cbGroupWrite, state.groupWrite), (cbGroupExec, state.groupExecute),
            (cbOtherRead, state.otherRead), (cbOtherWrite, state.otherWrite), (cbOtherExec, state.otherExecute),
            (cbSetUID, state.setUID), (cbSetGID, state.setGID), (cbSticky, state.sticky),
            (cbRecursive, state.recursive),
        ]
        for (button, on) in pairs { button.state = on ? .on : .off }
        octalLabel.stringValue = state.octalString
        symbolicLabel.stringValue = state.symbolicString
        updatePresetChips()
    }

    private func updatePresetChips() {
        for chip in presetChips {
            let active = chip.mode == state.mode
            chip.button.bezelColor = active ? AppWindows.accent : nil
            let attr = NSMutableAttributedString(string: "\(chip.title) ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: active ? NSColor.white : NSColor.labelColor,
            ])
            attr.append(NSAttributedString(string: chip.sub, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: active ? NSColor.white.withAlphaComponent(0.9) : NSColor.secondaryLabelColor,
            ]))
            chip.button.attributedTitle = attr
        }
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
        updatePresetChips()
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

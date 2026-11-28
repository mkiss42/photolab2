// PathAndTabBars.swift
// Path bar (clickable breadcrumbs that turn into an editable path field) and the tab bar.

import AppKit

protocol PathBarDelegate: class {
    func pathBarNavigate(_ path: String)
    func pathBarSubmit(_ text: String)
    /// 1.0.0-alpha.6: files dropped on a folder of the path bar (same copy/move as any other drop).
    func pathBarDrop(_ paths: [String], into folder: String, move: Bool)
}

final class PathBarView: FillView, NSTextFieldDelegate {
    weak var delegate: PathBarDelegate?
    private let stack = NSStackView()
    private let field = NSTextField()
    private(set) var path = "/"
    private(set) var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        stack.setHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead
        field.delegate = self
        field.isHidden = true
        field.placeholderString = "Type a path (~/Pictures, /Volumes/Drive) or a network address (\\\\192.168.1.10\\Share, smb://server/share)"
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        fillColor = tm.background
        field.backgroundColor = tm.background
        field.textColor = tm.text
        field.font = tm.font
        rebuild()
    }

    func setPath(_ p: String) {
        path = p
        customCrumbs = nil
        if !isEditing { rebuild() }
    }

    /// 0.16: crumbs that aren't a local path (an FTP pane). `editText` is what typing starts from.
    private var customCrumbs: [(name: String, path: String)]? = nil

    func setCrumbs(_ c: [(name: String, path: String)], editText: String) {
        path = editText
        customCrumbs = c
        if !isEditing { rebuild() }
    }

    /// Breadcrumbs. Paths under /Volumes start at the volume name.
    private func rebuild() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let tm = ThemeManager.shared
        var crumbs: [(name: String, path: String)]
        if let c = customCrumbs {
            crumbs = c
        } else {
            crumbs = Paths.crumbs(path)
            var rootTitle = "Macintosh HD"
            if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]), let n = v.volumeName { rootTitle = n }
            if crumbs.count >= 3 && crumbs[1].path == "/Volumes" {
                crumbs = Array(crumbs.dropFirst(2))
            } else {
                crumbs[0] = (rootTitle, "/")
            }
        }
        var shown: [(name: String, path: String)?] = crumbs.map { Optional($0) }
        if crumbs.count > 12 {
            let head: [(name: String, path: String)?] = [Optional(crumbs[0]), nil]
            let tail: [(name: String, path: String)?] = crumbs.suffix(10).map { Optional($0) }
            shown = head + tail
        }
        for (i, c) in shown.enumerated() {
            if i > 0 {
                let sep = makeLabel("\u{203A}")
                sep.textColor = tm.secondaryText
                sep.font = tm.font
                stack.addArrangedSubview(sep)
            }
            guard let crumb = c else {
                let dots = makeLabel("\u{2026}")
                dots.textColor = tm.secondaryText
                dots.font = tm.font
                stack.addArrangedSubview(dots)
                continue
            }
            // Full names; the button shortens a name only when the bar really runs out of room.
            let title = crumb.name
            let b = PathCrumbButton(title: title, target: self, action: #selector(crumbClicked(_:)))
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.toolTip = crumb.path
            b.applyTheme(title)
            b.identifier = itemID(crumb.path)
            // 1.0.0-alpha.5: local folders can be dragged out (not FTP crumbs).
            b.dragPath = customCrumbs == nil && crumb.path.hasPrefix("/") ? crumb.path : nil
            // 1.0.0-alpha.6: and they take drops (files dragged onto a folder go into it).
            if b.dragPath != nil {
                b.registerForDraggedTypes(FileDrag.types)
                b.onDrop = { [weak self] paths, dest, move in self?.delegate?.pathBarDrop(paths, into: dest, move: move) }
            }
            let isLast = i == shown.count - 1
            b.attributedTitle = attributed(title, font: isLast ? tm.boldFont : tm.font, color: isLast ? tm.text : tm.secondaryText)
            // Above the search field's wish to be wide (250), below its minimum width (required).
            b.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 300), for: .horizontal)
            (b.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(b)
        }
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard let p = sender.identifier?.rawValue else { return }
        delegate?.pathBarNavigate(p)
    }

    /// Clicking the empty part of the bar starts typing a path.
    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    func beginEditing() {
        isEditing = true
        stack.isHidden = true
        field.isHidden = false
        field.stringValue = path
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        stack.isHidden = false
        rebuild()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue
            endEditing()
            delegate?.pathBarSubmit(text)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    // Informal NSObject method in the 10.13 SDK (needs `override`); a protocol method in later SDKs.
    #if swift(>=4.2)
    func controlTextDidEndEditing(_ obj: Notification) {
        endEditing()
    }
    #else
    override func controlTextDidEndEditing(_ obj: Notification) {
        endEditing()
    }
    #endif
}

/// 1.0.0-alpha.5: a folder in the path bar can be dragged out, as in Finder's path bar: onto an
/// application in the Dock (opens the folder with it), into Finder, Photoshop, a dialog... A click
/// still goes to the folder. Inside PhotoLab the drag only copies (never moves the folder you are in).
/// The drag image is the generic folder icon: nothing reads the folder (it may be on a share).
/// 1.0.0-alpha.6: also a drop target - files dragged onto a folder of the path bar go into it, with the
/// same rules as any drop in PhotoLab (same drive = move, other drive = copy, Option = copy,
/// Command = move; verified, never overwriting; onto itself or its own subfolder refused).
final class PathCrumbButton: ThemedButton, NSDraggingSource {
    /// The folder to drag; nil = not draggable (FTP crumbs).
    var dragPath: String?
    /// Files dropped on this folder: (paths, folder, move).
    var onDrop: (([String], String, Bool) -> Void)?

    private func setDropHighlight(_ on: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = on ? ThemeManager.shared.selection.withAlphaComponent(0.55).cgColor : nil
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let dest = dragPath, onDrop != nil else { return [] }
        let op = FileDrag.operation(info, sources: FileDrag.paths(info), dest: dest)
        setDropHighlight(!op.isEmpty)
        return op
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { return dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { return dropOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlight(false) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setDropHighlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let op = dropOperation(sender)
        setDropHighlight(false)
        guard let dest = dragPath, !op.isEmpty else { return false }
        onDrop?(FileDrag.paths(sender), dest, op == .move)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let path = dragPath, let win = window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        isHighlighted = true
        defer { isHighlighted = false }
        while let e = win.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if e.type == .leftMouseUp {
                // A click: go to the folder, as before (Cmd-click = new window, read from this event).
                if bounds.contains(convert(e.locationInWindow, from: nil)) { _ = sendAction(action, to: target) }
                return
            }
            let dx = e.locationInWindow.x - start.x, dy = e.locationInWindow.y - start.y
            if dx * dx + dy * dy >= 16 {
                beginDrag(path, event: event)
                return
            }
        }
    }

    private func beginDrag(_ path: String, event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: path))
        let icon = NSWorkspace.shared.icon(forFileType: "public.folder")
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), contents: icon)
        App.log.info("DRAG 1 folder from the path bar")
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        FileDrag.addFilenames(session.draggingPasteboard, [path])
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .copy : [.copy, .link, .generic]
    }
}

protocol TabBarDelegate: class {
    func tabBarSelect(_ index: Int)
    func tabBarClose(_ index: Int)
    func tabBarNew()
}

/// One tab: click to select, x to close.
final class TabChip: NSView {
    var index = 0
    var active = false
    var title = "" {
        didSet { needsDisplay = true }
    }
    weak var bar: TabBarView?
    private let closeButton: ThemedButton

    override init(frame frameRect: NSRect) {
        closeButton = makeButton("\u{00D7}", nil, #selector(TabChip.closeClicked(_:)), tip: "Close Tab")
        super.init(frame: frameRect)
        closeButton.target = self
        addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func applyTheme() {
        closeButton.applyTheme("\u{00D7}")
    }

    @objc func closeClicked(_ sender: Any?) {
        bar?.delegate?.tabBarClose(index)
    }

    override func mouseDown(with event: NSEvent) {
        bar?.delegate?.tabBarSelect(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        let r = bounds.insetBy(dx: 2, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        if active {
            tm.accent.withAlphaComponent(0.22).setFill()
            path.fill()
            tm.accent.setStroke()
        } else {
            tm.separator.setStroke()
        }
        path.lineWidth = 1
        path.stroke()
        let t = attributed(title, font: active ? tm.boldFont : tm.font, color: active ? tm.text : tm.secondaryText)
        let s = t.size()
        let maxW = r.width - 40
        let w = min(s.width, maxW)
        let tr = NSRect(x: r.midX - w / 2, y: r.midY - s.height / 2, width: max(0, w), height: s.height)
        t.draw(with: tr, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], context: nil)
    }
}

final class TabBarView: FillView {
    weak var delegate: TabBarDelegate?
    private let stack = NSStackView()
    private var newButton: ThemedButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        addSubview(stack)
        newButton = makeButton("+", self, #selector(newClicked(_:)), tip: "New Tab")
        addSubview(newButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        newButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -4),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func newClicked(_ sender: Any?) {
        delegate?.tabBarNew()
    }

    func setTabs(_ titles: [String], active: Int) {
        let tm = ThemeManager.shared
        fillColor = tm.sidebar
        bottomLine = tm.separator
        newButton.applyTheme("+")
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, t) in titles.enumerated() {
            let chip = TabChip(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            chip.index = i
            chip.active = i == active
            chip.title = t
            chip.bar = self
            chip.applyTheme()
            stack.addArrangedSubview(chip)
            chip.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
    }
}

// ReportWindow.swift
// A plain, non-modal text window for self-test results and the Short Report: monospaced, selectable,
// easy to read off the screen and retype. Non-modal on purpose: a modal alert stops the main queue
// and shows up as a false FREEZE in the log.

import AppKit

final class ReportWindow: NSWindowController {
    private static var shared: ReportWindow?
    private let textView = NSTextView()

    static func show(title: String, text: String) {
        let w = shared ?? ReportWindow()
        shared = w
        w.window?.title = title
        w.textView.string = text
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        super.init(window: win)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.userFixedPitchFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.frame = NSRect(x: 0, y: 0, width: 760, height: 360)
        textView.minSize = NSSize(width: 0, height: 360)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        win.contentView = scroll
        win.center()
        win.isReleasedWhenClosed = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

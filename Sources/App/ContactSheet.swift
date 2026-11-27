// ContactSheet.swift
// Contact sheet PDF: a grid of pictures (RAW: embedded camera preview) with file names and optionally
// camera settings, page header and page numbers. Pictures are embedded as JPEG so the PDF stays small.
// Rendering only produces data; saving goes through FileOperations.writeNewFile (never overwrites).

import AppKit
import CoreText
import ImageIO

struct ContactSheetOptions {
    var columns = 5
    var rows = 6
    var pageWidth = 612.0
    var pageHeight = 792.0
    var paperName = "US Letter"
    var showSettings = true
    var title = ""

    static let papers: [(String, Double, Double)] = [
        ("US Letter, portrait", 612, 792), ("US Letter, landscape", 792, 612),
        ("A4, portrait", 595, 842), ("A4, landscape", 842, 595),
        ("US Tabloid (11 x 17), portrait", 792, 1224),
    ]

    /// Ask for columns, rows, paper, captions and title (remembered for next time). nil = cancelled.
    static func ask(count: Int, title: String) -> ContactSheetOptions? {
        let d = UserDefaults.standard
        let a = ThemedAlert()
        a.messageText = "Contact sheet of \(ContactSheetLayout.plural(count, "picture"))"
        a.informativeText = "Saved as a PDF in the current folder (a new file; nothing is overwritten), then opened in Adobe Acrobat."
        let cols = NSPopUpButton(frame: .zero, pullsDown: false)
        cols.addItems(withTitles: (1...12).map { "\($0)" })
        cols.selectItem(at: max(0, min(11, (d.integer(forKey: "csColumns") > 0 ? d.integer(forKey: "csColumns") : 5) - 1)))
        let rows = NSPopUpButton(frame: .zero, pullsDown: false)
        rows.addItems(withTitles: (1...15).map { "\($0)" })
        rows.selectItem(at: max(0, min(14, (d.integer(forKey: "csRows") > 0 ? d.integer(forKey: "csRows") : 6) - 1)))
        let paper = NSPopUpButton(frame: .zero, pullsDown: false)
        paper.addItems(withTitles: papers.map { $0.0 })
        paper.selectItem(at: max(0, min(papers.count - 1, d.integer(forKey: "csPaper"))))
        let settings = NSButton(checkboxWithTitle: "Camera settings under each picture", target: nil, action: nil)
        settings.state = d.object(forKey: "csSettings") == nil || d.bool(forKey: "csSettings") ? .on : .off
        let titleField = NSTextField(string: title)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        func row(_ label: String, _ views: [NSView]) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let r = NSStackView(views: [l] + views)
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        let stack = NSStackView(views: [row("Title:", [titleField]),
                                        row("Columns:", [cols, NSTextField(labelWithString: "Rows:"), rows]),
                                        row("Paper:", [paper]), settings])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
        a.accessoryView = stack
        a.addButton(withTitle: "Make Contact Sheet")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return nil }
        var o = ContactSheetOptions()
        o.columns = 1 + max(0, cols.indexOfSelectedItem)
        o.rows = 1 + max(0, rows.indexOfSelectedItem)
        let pi = max(0, min(papers.count - 1, paper.indexOfSelectedItem))
        let p = papers[pi]
        o.paperName = p.0
        o.pageWidth = p.1
        o.pageHeight = p.2
        o.showSettings = settings.state == .on
        o.title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        d.set(o.columns, forKey: "csColumns")
        d.set(o.rows, forKey: "csRows")
        d.set(pi, forKey: "csPaper")
        d.set(o.showSettings, forKey: "csSettings")
        return o
    }
}

enum ContactSheetMaker {
    /// Render the PDF. Blocking (call off the main thread). `progress` gets the number of pictures done.
    static func render(_ pics: [FileEntry], options o: ContactSheetOptions, progress: (Int) -> Void) -> Data? {
        let layout = ContactSheetLayout(pageWidth: o.pageWidth, pageHeight: o.pageHeight, columns: o.columns, rows: o.rows)
        let pages = layout.pages(for: pics.count)
        let out = NSMutableData()
        guard pages > 0, let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: o.pageWidth, height: o.pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let px = Int(min(1600, max(300, max(layout.cellWidth, layout.cellHeight) * 2.5)))
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let grey = CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)
        let frameGrey = CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
        let nameSize: CGFloat = layout.cellWidth < 90 ? 6 : 7

        // Captions first (each row's caption space = its tallest caption).
        var captions: [NSAttributedString] = []
        var captionHeights: [Double] = []
        for e in pics {
            var settingsLine = ""
            if o.showSettings {
                let secs = InspectorController.details(for: e).sections
                var rows: [String: String] = [:]
                for s in secs { for (k, v) in s.rows { rows[k] = rows[k] ?? v } }
                settingsLine = [rows["Focal length"], rows["Aperture"], rows["Shutter speed"], rows["ISO"].map { "ISO " + $0 },
                                rows["Rating"].flatMap { $0.contains("\u{2605}") ? $0.components(separatedBy: " (").first : nil }]
                    .compactMap { $0 }.joined(separator: "  ")
            }
            let cap = caption(e.name, settingsLine, nameSize: nameSize, black: black, grey: grey)
            captions.append(cap)
            captionHeights.append(textHeight(cap, width: layout.cellWidth))
        }
        var rowCaption: [String: Double] = [:]
        for i in 0..<pics.count {
            let c = layout.cell(i)
            let k = "\(c.page)-\(c.row)"
            rowCaption[k] = max(rowCaption[k] ?? 0, captionHeights[i])
        }

        var page = -1
        for (i, e) in pics.enumerated() {
            let c = layout.cell(i)
            if c.page != page {
                if page >= 0 { ctx.endPDFPage() }
                page = c.page
                ctx.beginPDFPage(nil)
                let heading = o.title.isEmpty ? "Contact Sheet" : o.title
                text(ctx, heading, x: layout.margin, top: layout.margin, width: o.pageWidth * 0.6, size: 12, color: black, pageHeight: o.pageHeight)
                text(ctx, "\(ContactSheetLayout.plural(pics.count, "picture"))  \u{00B7}  \(date)", x: o.pageWidth * 0.55, top: layout.margin + 2,
                     width: o.pageWidth * 0.45 - layout.margin, size: 8, color: grey, pageHeight: o.pageHeight, alignRight: true)
                text(ctx, "Page \(page + 1) of \(pages)", x: layout.margin, top: o.pageHeight - layout.margin - 10,
                     width: o.pageWidth - 2 * layout.margin, size: 8, color: grey, pageHeight: o.pageHeight, alignRight: true)
            }
            let capH = rowCaption["\(c.page)-\(c.row)"] ?? captionHeights[i]
            let pb = layout.pictureBox(x: c.x, y: c.y, w: c.w, h: c.h, captionHeight: capH)
            let boxRect = CGRect(x: pb.x, y: o.pageHeight - pb.y - pb.h, width: pb.w, height: pb.h)
            ctx.setStrokeColor(frameGrey)
            ctx.setLineWidth(0.5)
            ctx.stroke(boxRect)
            if let pv = ImageMeta.preview(path: e.path, maxPixels: px), let jpeg = jpegImage(pv.image) {
                let f = layout.fit(imageWidth: Double(jpeg.width), height: Double(jpeg.height), inBox: pb)
                ctx.draw(jpeg, in: CGRect(x: f.x, y: o.pageHeight - f.y - f.h, width: f.w, height: f.h))
            } else {
                text(ctx, "(no preview)", x: pb.x, top: pb.y + pb.h / 2 - 5, width: pb.w, size: 7, color: grey, pageHeight: o.pageHeight, center: true)
            }
            // Full name, wrapped onto as many lines as it needs.
            drawWrapped(ctx, captions[i], x: c.x, top: pb.y + pb.h + 3, width: c.w, height: captionHeights[i] + 2, pageHeight: o.pageHeight)
            progress(i + 1)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return out.length > 0 ? Data(referencing: out) : nil
    }

    private static func caption(_ name: String, _ settings: String, nameSize: CGFloat, black: CGColor, grey: CGColor) -> NSAttributedString {
        // Centred, word-wrapped (Core Text breaks a name with no spaces wherever it has to).
        var alignment = CTTextAlignment.center
        let para: CTParagraphStyle = withUnsafePointer(to: &alignment) { ptr in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let paraKey = AttrKey(rawValue: kCTParagraphStyleAttributeName as String)
        let nameFont = CTFontCreateWithName("Helvetica" as CFString, nameSize, nil)
        let smallFont = CTFontCreateWithName("Helvetica" as CFString, nameSize - 1, nil)
        let out = NSMutableAttributedString(string: "")
        out.append(NSAttributedString(string: name, attributes: [AttrKey(rawValue: kCTFontAttributeName as String): nameFont,
                                                                 AttrKey(rawValue: kCTForegroundColorAttributeName as String): black,
                                                                 paraKey: para]))
        if !settings.isEmpty {
            out.append(NSAttributedString(string: "\n" + settings, attributes: [AttrKey(rawValue: kCTFontAttributeName as String): smallFont,
                                                                               AttrKey(rawValue: kCTForegroundColorAttributeName as String): grey,
                                                                               paraKey: para]))
        }
        return out
    }

    private static func textHeight(_ s: NSAttributedString, width: Double) -> Double {
        let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: 100_000), nil)
        return Double(ceil(size.height))
    }

    private static func drawWrapped(_ ctx: CGContext, _ s: NSAttributedString, x: Double, top: Double, width: Double, height: Double, pageHeight: Double) {
        let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let rect = CGRect(x: x, y: pageHeight - top - height, width: width, height: height)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    /// Open the saved sheet in Adobe Acrobat (Pro or Reader). Returns false if Acrobat isn't installed;
    /// then the Mac's default PDF app is used.
    @discardableResult
    static func openInAcrobat(_ path: String) -> Bool {
        let ws = NSWorkspace.shared
        let ids = ["com.adobe.Acrobat.Pro", "com.adobe.Acrobat", "com.adobe.Reader", "com.adobe.AdobeAcrobatReader"]
        for id in ids {
            if let app = ws.absolutePathForApplication(withBundleIdentifier: id), ws.openFile(path, withApplication: app) {
                Log.shared?.info("Contact sheet opened in \(app)")
                return true
            }
        }
        for name in ["Adobe Acrobat", "Adobe Acrobat DC", "Adobe Acrobat Pro DC", "Adobe Acrobat Reader DC", "Adobe Acrobat Reader"] {
            if let app = ws.fullPath(forApplication: name), ws.openFile(path, withApplication: app) {
                Log.shared?.info("Contact sheet opened in \(app)")
                return true
            }
        }
        ws.openFile(path)
        Log.shared?.info("Acrobat not found; contact sheet opened in the default PDF app")
        return false
    }

    /// Re-encode as JPEG so the PDF embeds compressed pictures.
    private static func jpegImage(_ img: CGImage) -> CGImage? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return img }
        let props = NSDictionary(dictionary: [kCGImageDestinationLossyCompressionQuality as String: 0.82])
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: d as CFData),
            let j = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return img }
        return j
    }

    /// One line of text (Core Text, safe off the main thread), truncated in the middle to fit.
    private static func text(_ ctx: CGContext, _ s: String, x: Double, top: Double, width: Double, size: CGFloat,
                             color: CGColor, pageHeight: Double, center: Bool = false, alignRight: Bool = false) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [AttrKey: Any] = [AttrKey(rawValue: kCTFontAttributeName as String): font,
                                     AttrKey(rawValue: kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs) as CFAttributedString)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs) as CFAttributedString)
        let fitted = CTLineCreateTruncatedLine(line, width, .middle, ellipsis) ?? line
        let w = Double(CTLineGetTypographicBounds(fitted, nil, nil, nil))
        var px = x
        if center { px = x + max(0, (width - w) / 2) }
        if alignRight { px = x + max(0, width - w) }
        ctx.textPosition = CGPoint(x: px, y: pageHeight - top - Double(size))
        CTLineDraw(fitted, ctx)
    }
}

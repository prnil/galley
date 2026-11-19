import AppKit
import PDFKit
import UniformTypeIdentifiers

enum Layout: Int { case source = 0, both = 1, pages = 2 }

extension NSToolbarItem.Identifier {
    static let gTitle = Self("galley.title")
    static let gTypeset = Self("galley.typeset")
    static let gEngine = Self("galley.engine")
    static let gLayout = Self("galley.layout")
}

/// The source sheet: the editor on taped paper, the footer, and the slip TeX's complaints go on.
final class SourcePane: NSView {
    let sheet = PaperView(stock: Theme.paperStock)
    let scroll: NSScrollView
    let text: SourceTextView
    let footer = NSTextField(labelWithString: "")
    let issues = IssueSlip()

    override init(frame: NSRect) {
        (scroll, text) = SourceTextView.make()
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for v in [sheet, footer, issues] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sheet.addSubview(scroll)
        footer.font = Theme.mono(10.5)
        footer.textColor = Theme.text3
        footer.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sheet.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            sheet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34),
            scroll.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sheet.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sheet.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 4),
            footer.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -4),
            footer.topAnchor.constraint(equalTo: sheet.bottomAnchor, constant: 11),
            issues.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 34),
            issues.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -26),
            issues.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -16),
        ])
        sheet.tape(at: 0.12, width: 64, angle: -6, seed: 11)
        sheet.tape(at: 0.9, width: 58, angle: 5, seed: 23)
        issues.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The text view is as wide as the sheet, so long lines wrap inside it.
    override func layout() {
        super.layout()
        let w = scroll.contentSize.width
        if w > 0, abs(text.frame.width - w) > 0.5 { text.setFrameSize(NSSize(width: w, height: text.frame.height)) }
    }
}

/// A taped slip listing what TeX said, newest run only. Each line jumps to its source.
final class IssueSlip: PaperView {
    private let stack = NSStackView()
    private let title = handLabel("TeX says", size: 15, bold: true)
    private let underline = InkLayer()
    private let close = NSButton()
    var onPick: ((TeXIssue) -> Void)?
    var onClose: (() -> Void)?
    private var shown: [TeXIssue] = []

    init() {
        super.init(stock: Theme.card, slip: true)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for v in [title, stack, close] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide")
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.contentTintColor = Theme.text3
        close.target = self
        close.action = #selector(hide)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
        underline.shape = .underline
        underline.pen = Pen.brush.scaled(0.7)
        underline.ink = Theme.clay
        underline.owner = self
        underline.seed = 314
        layer?.addSublayer(underline)
        tape(at: 0.5, width: 50, angle: 3, seed: 51)
        frameCenterRotation = -0.6
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = title.frame
        underline.frame = NSRect(x: t.minX - 2, y: t.maxY + 1, width: t.width + 6, height: 6)
        CATransaction.commit()
    }

    @objc private func hide() { onClose?() }

    /// Shows up to five issues; returns false when there is nothing to show.
    @discardableResult
    func show(_ list: [TeXIssue], mainFile: String) -> Bool {
        let picked = Array(list.prefix(5))
        guard !picked.isEmpty else { return false }
        let changed = picked != shown
        shown = picked
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let errs = list.filter { $0.kind == .error }.count
        title.stringValue = errs > 0 ? (errs == 1 ? "TeX stopped on 1 error" : "TeX found \(errs) errors") : "TeX has \(list.count) warning\(list.count == 1 ? "" : "s")"
        underline.ink = errs > 0 ? Theme.clay : Theme.accent
        for issue in picked {
            let b = NSButton()
            b.isBordered = false
            b.alignment = .left
            b.lineBreakMode = .byTruncatingTail
            var where_ = ""
            if let l = issue.line {
                let f = issue.file.map { $0 == mainFile ? "" : ($0 as NSString).lastPathComponent + " " } ?? ""
                where_ = "\(f)l.\(l)  "
            }
            let s = NSMutableAttributedString(string: where_, attributes: [.font: Theme.mono(11), .foregroundColor: issue.kind == .error ? Theme.clay : Theme.accent])
            s.append(NSAttributedString(string: issue.message, attributes: [.font: Theme.hand(13), .foregroundColor: Theme.text]))
            b.attributedTitle = s
            b.target = self
            b.action = #selector(pick(_:))
            b.tag = stack.arrangedSubviews.count
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(b)
        }
        if changed || isHidden {
            if isHidden { isHidden = false; Motion.rise(layer, by: 16, dur: 0.45) }
            underline.drawOn(dur: 0.5, delay: 0.1)
        }
        return true
    }

    @objc private func pick(_ b: NSButton) {
        guard b.tag < shown.count else { return }
        onPick?(shown[b.tag])
    }

    func clear() { shown = []; isHidden = true }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextViewDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    let doc: TeXDocument
    let split = PencilSplitView()
    let source = SourcePane()
    let preview = PreviewPane()
    private let tabs = InkTabs(["Source", "Both", "Pages"], selected: 1)
    private let status = StatusMark()
    private let titleLabel = handLabel("", size: 16, bold: true)
    private var engineButton: InkButton!
    private var typesetter: Typesetter?
    private var timer: Timer?
    private var busy = false
    private var again: Bool? = nil   // queued run (full or not)
    private var last: TypesetResult?
    private var slipDismissed = false
    private var editsSinceRun = false
    private(set) var layoutMode: Layout = .both
    private var engineOverride: Engine?
    /// Snapshot runs wait on this.
    var onTypeset: ((TypesetResult) -> Void)?

    init(document: TeXDocument) {
        doc = document
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.delegate = self
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Theme.ink
        w.minSize = NSSize(width: 640, height: 420)
        w.tabbingMode = .preferred
        w.setFrameAutosaveName("GalleyEditor")
        if w.frame.width < 700 { w.center() }
        shouldCascadeWindows = true

        let tb = NSToolbar(identifier: "GalleyToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unified

        let root = DeskView()
        w.contentView = root
        split.translatesAutoresizingMaskIntoConstraints = false
        split.delegate = self
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        split.addArrangedSubview(source)
        split.addArrangedSubview(preview)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)

        let tv = source.text
        let hl = TeXHighlighter()
        hl.isBib = doc.isBib
        highlighter = hl
        tv.textStorage?.delegate = hl
        tv.delegate = self
        tv.string = doc.text
        tv.onSync = { [weak self] line in self?.showInPDF(line: line) }
        doc.liveText = { [weak tv] in tv?.string ?? "" }
        preview.pdf.onSyncEdit = { [weak self] page, x, y in self?.syncEdit(page: page, x: x, y: y) }
        source.issues.onPick = { [weak self] issue in self?.jump(to: issue) }
        source.issues.onClose = { [weak self] in self?.slipDismissed = true; self?.source.issues.clear() }
        tabs.onChange = { [weak self] i in self?.setLayout(Layout(rawValue: i) ?? .both) }

        let saved = UserDefaults.standard.object(forKey: "GalleyLayout") as? Int
        let start: Layout = !doc.isTypesettable ? .source : Layout(rawValue: saved ?? 1) ?? .both
        setLayout(start, animated: false)
        updateTitle()
        updateFooter()

        if doc.isTypesettable {
            if !Typesetter.available {
                preview.setEmpty("TeX is not installed.\nGalley uses MacTeX from /Library/TeX.")
            } else {
                preview.setEmpty("Setting type…")
                DispatchQueue.main.async { [weak self] in self?.typeset(full: false) }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var highlighter: TeXHighlighter?

    override func windowDidLoad() { super.windowDidLoad() }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window || window?.firstResponder == nil { window?.makeFirstResponder(source.text) }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        typesetter?.cancel()
        if let t = typesetter { try? FileManager.default.removeItem(at: t.dir) }
    }

    // MARK: Layout

    func setLayout(_ l: Layout, animated: Bool = true) {
        layoutMode = l
        tabs.select(l.rawValue, animated: animated)
        if doc.isTypesettable, !Prefs.probing { UserDefaults.standard.set(l.rawValue, forKey: "GalleyLayout") }
        let showSource = l != .pages, showPages = l != .source && doc.isTypesettable
        source.isHidden = !showSource
        preview.isHidden = !showPages
        split.adjustSubviews()
        if showSource && showPages {
            if split.bounds.width > 100 { split.setPosition(floor(split.bounds.width * 0.5), ofDividerAt: 0) }
            else { split.pendingFraction = 0.5 }
        }
        split.needsLayout = true
        if showPages { preview.pdf.fitting = true; preview.pdf.needsLayout = true }
        if animated {
            Motion.rise(showPages && l == .pages ? preview.layer : source.sheet.layer, by: 10, dur: 0.4)
        }
        if showSource { window?.makeFirstResponder(source.text) }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { 300 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { splitView.bounds.width - 300 }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.gTitle, .flexibleSpace, .gLayout, .gEngine, .gTypeset]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.gTitle, .flexibleSpace, .gLayout, .flexibleSpace, .gEngine, .gTypeset]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .gTitle:
            item.view = titleLabel
            item.label = "Title"
        case .gLayout:
            item.view = tabs
            item.label = "Layout"
        case .gEngine:
            let b = InkButton(title: Prefs.defaultEngine.title, target: self, action: #selector(engineMenu(_:)))
            b.isBordered = false
            b.font = Theme.mono(11.5)
            b.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            b.symbolConfiguration = .init(pointSize: 8, weight: .bold)
            b.imagePosition = .imageTrailing
            b.contentTintColor = Theme.text2
            b.toolTip = "Which TeX engine sets the type. A % !TEX program = … line at the top of the file wins."
            engineButton = b
            item.view = b
            item.label = "Engine"
            refreshEngine()
        case .gTypeset:
            let b = InkButton(title: "Typeset", target: self, action: #selector(typesetFull(_:)))
            b.isBordered = false
            b.font = Theme.hand(14, bold: true)
            b.toolTip = "Typeset with bibliography (⌘B). Galley also sets type as you write."
            let row = NSStackView(views: [status, b])
            row.spacing = 6
            item.view = row
            item.label = "Typeset"
        default: return nil
        }
        return item
    }

    private func updateTitle() {
        titleLabel.stringValue = doc.displayName ?? "Untitled"
        window?.title = doc.displayName ?? "Untitled"
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateTitle()
    }

    // MARK: Engine

    var engine: Engine { Engine.magic(in: source.text.string) ?? engineOverride ?? Prefs.defaultEngine }

    private func refreshEngine() {
        guard let b = engineButton else { return }
        b.title = engine.title
        b.font = Theme.mono(11.5)
        b.isHidden = !doc.isTypesettable
    }

    @objc func engineMenu(_ sender: NSButton) {
        let m = NSMenu()
        for e in Engine.installed {
            let i = m.addItem(withTitle: e.title, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = e.rawValue
            i.state = e == engine ? .on : .off
        }
        if Engine.magic(in: source.text.string) != nil {
            m.addItem(.separator())
            m.addItem(withTitle: "Set by % !TEX program in the file", action: nil, keyEquivalent: "").isEnabled = false
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = Engine(rawValue: raw) else { return }
        engineOverride = e
        Prefs.defaultEngine = e
        refreshEngine()
        typeset(full: false)
    }

    // MARK: Typesetting

    func textDidChange(_ notification: Notification) {
        doc.updateChangeCount(.changeDone)
        editsSinceRun = true
        updateFooter()
        guard doc.isTypesettable, Prefs.liveTypeset else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in self?.typeset(full: false) }
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateFooter() }

    private func makeTypesetter() -> Typesetter {
        let url = doc.fileURL
        let name = url?.deletingPathExtension().lastPathComponent ?? "untitled"
        let id = url.map { String(Ink.seed($0.path), radix: 16) + "-" + String(ProcessInfo.processInfo.processIdentifier) } ?? UUID().uuidString
        return Typesetter(id: id, name: name, sourceFolder: url?.deletingLastPathComponent())
    }

    @objc func typesetNow(_ sender: Any?) { typeset(full: false) }
    @objc func typesetFull(_ sender: Any?) { typeset(full: true) }

    func typeset(full: Bool) {
        guard doc.isTypesettable, Typesetter.available else { return }
        timer?.invalidate()
        if busy { again = (again ?? false) || full; return }
        if typesetter == nil || typesetter?.sourceFolder != doc.fileURL?.deletingLastPathComponent() {
            if let old = typesetter { try? FileManager.default.removeItem(at: old.dir) }
            typesetter = makeTypesetter()
        }
        guard let t = typesetter else { return }
        busy = true
        editsSinceRun = false
        status.set(.working)
        refreshEngine()
        t.typeset(source.text.string, engine: engine, full: full) { [weak self] r in self?.finished(r) }
    }

    private func finished(_ r: TypesetResult) {
        busy = false
        var r = r
        if let pdf = r.pdf {
            preview.load(pdf)
            r.pages = preview.pdf.document?.pageCount ?? 0
            if r.errors.isEmpty {
                preview.effects.toast(at: CGPoint(x: preview.bounds.midX, y: 54), symbol: nil,
                                      text: String(format: "set in %.1f s", r.seconds), hold: 0.5)
            }
        } else if preview.pdf.document == nil {
            preview.setEmpty("No pages yet.\nTeX's complaints are on the slip.")
        }
        last = r
        status.set(r.errors.isEmpty && r.pdf != nil ? .ok : .failed)
        let main = typesetter?.texCopy.path ?? ""
        source.text.errorLines = Set(r.errors.filter { $0.file == main }.compactMap(\.line))
        source.text.warningLines = Set(r.warnings.filter { $0.file == main && $0.kind == .warning }.compactMap(\.line))
        if r.errors.isEmpty {
            source.issues.clear()
            slipDismissed = false
        } else if !slipDismissed {
            source.issues.show(r.errors, mainFile: main)
        }
        updateFooter()
        onTypeset?(r)
        if let full = again {
            again = nil
            typeset(full: full)
        }
    }

    private func updateFooter() {
        let tv = source.text
        let words = tv.string.split { $0.isWhitespace || $0.isNewline }.lazy.filter { !$0.hasPrefix("\\") && !$0.hasPrefix("%") }.count
        var parts = ["line \(tv.currentLine), col \(tv.currentColumn + 1)", "\(NumberFormatter.localizedString(from: words as NSNumber, number: .decimal)) words"]
        if doc.isTypesettable, let r = last {
            parts.append(r.errors.isEmpty ? String(format: "%@ · %.1f s", engine.title, r.seconds) : "\(r.errors.count) error\(r.errors.count == 1 ? "" : "s")")
            let w = r.warnings.filter { $0.kind == .warning }.count
            if w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
            if r.pages > 0 { parts.append("\(r.pages) page\(r.pages == 1 ? "" : "s")") }
        }
        source.footer.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: Errors

    @objc func showIssues(_ sender: Any?) {
        guard let r = last else { return }
        slipDismissed = false
        let list = r.errors.isEmpty ? r.warnings.filter { $0.kind == .warning } : r.errors
        if !source.issues.show(list, mainFile: typesetter?.texCopy.path ?? "") { NSSound.beep() }
    }

    @objc func nextIssue(_ sender: Any?) {
        guard let r = last else { return }
        let main = typesetter?.texCopy.path ?? ""
        let lines = (r.errors.isEmpty ? r.warnings : r.errors).filter { $0.file == main }.compactMap(\.line).sorted()
        guard !lines.isEmpty else { NSSound.beep(); return }
        let cur = source.text.currentLine
        source.text.reveal(line: lines.first { $0 > cur } ?? lines[0])
    }

    private func jump(to issue: TeXIssue) {
        guard let line = issue.line else { return }
        let main = typesetter?.texCopy.path
        if issue.file == nil || issue.file == main {
            if layoutMode == .pages { setLayout(.both) }
            source.text.reveal(line: line)
        } else if let f = issue.file {
            open(file: f, line: line)
        }
    }

    private func open(file: String, line: Int) {
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: file) else { NSSound.beep(); return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { d, _, _ in
            guard let d = d as? TeXDocument, let wc = d.windowControllers.first as? EditorWindowController else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { wc.source.text.reveal(line: line) }
        }
    }

    // MARK: SyncTeX

    @objc func showInPDFAction(_ sender: Any?) { showInPDF(line: source.text.currentLine) }

    func showInPDF(line: Int) {
        guard let t = typesetter, preview.pdf.document != nil else { NSSound.beep(); return }
        if layoutMode == .source { setLayout(.both) }
        let col = source.text.currentColumn
        DispatchQueue.global(qos: .userInitiated).async {
            let spots = t.syncView(line: line, column: col)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let s = spots.first else { NSSound.beep(); return }
                // Several boxes on one line: circle their union on the first page.
                let same = spots.filter { $0.page == s.page && abs($0.y - s.y) < 4 }
                let minX = same.map(\.x).min() ?? s.x, maxX = same.map { $0.x + $0.w }.max() ?? s.x + s.w
                self.preview.circle(page: s.page, x: minX, y: s.y, w: maxX - minX, h: same.map(\.h).max() ?? s.h)
            }
        }
    }

    private func syncEdit(page: Int, x: Double, y: Double) {
        guard let t = typesetter else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let hit = t.syncEdit(page: page, x: x, y: y)
            DispatchQueue.main.async { [weak self] in
                guard let self, let hit else { NSSound.beep(); return }
                if hit.file == t.texCopy.path {
                    if self.layoutMode == .pages { self.setLayout(.both) }
                    self.source.text.reveal(line: hit.line)
                } else {
                    self.open(file: hit.file, line: hit.line)
                }
            }
        }
    }

    // MARK: Saving and export

    func documentSaved() {
        updateTitle()
        if Prefs.pdfBesideOnSave, let src = doc.fileURL, let pdf = typesetter?.pdf, FileManager.default.fileExists(atPath: pdf.path) {
            let dest = src.deletingPathExtension().appendingPathExtension("pdf")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: pdf, to: dest)
        }
        // The orange save seal, stamped on the pages (or the source when pages are hidden).
        if !preview.isHidden {
            preview.effects.seal(at: CGPoint(x: preview.bounds.maxX - 80, y: 96), word: "saved")
        }
        if editsSinceRun { typeset(full: false) }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let pdf = typesetter?.pdf, FileManager.default.fileExists(atPath: pdf.path) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".pdf"
        if let dir = doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? FileManager.default.removeItem(at: url)
            do { try FileManager.default.copyItem(at: pdf, to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc func printDocument(_ sender: Any?) {
        guard let d = preview.pdf.document, let op = d.printOperation(for: doc.printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true) else { NSSound.beep(); return }
        op.runModal(for: window!, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: View

    @objc func layoutSource(_ s: Any?) { setLayout(.source) }
    @objc func layoutBoth(_ s: Any?) { setLayout(.both) }
    @objc func layoutPages(_ s: Any?) { setLayout(.pages) }
    @objc func zoomInPages(_ s: Any?) { preview.pdf.zoomIn(s); preview.pdf.fitting = false }
    @objc func zoomOutPages(_ s: Any?) { preview.pdf.zoomOut(s); preview.pdf.fitting = false }
    @objc func fitPages(_ s: Any?) { preview.pdf.refit() }
    @objc func biggerText(_ s: Any?) { EditorMetrics.fontSize += 1; restyleText() }
    @objc func smallerText(_ s: Any?) { EditorMetrics.fontSize -= 1; restyleText() }
    @objc func toggleNumbers(_ s: Any?) { source.text.showsNumbers.toggle(); source.text.needsDisplay = true }
    @objc func toggleLive(_ s: Any?) { Prefs.liveTypeset.toggle() }
    @objc func togglePDFBeside(_ s: Any?) { Prefs.pdfBesideOnSave.toggle() }
    @objc func toggleComment(_ s: Any?) { source.text.toggleComment(s) }

    func restyleText() {
        guard let ts = source.text.textStorage else { return }
        source.text.font = TeXHighlighter.mono
        source.text.typingAttributes = TeXHighlighter.baseAttributes()
        highlighter?.colour(ts, in: NSRange(location: 0, length: ts.length))
        source.text.needsDisplay = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(layoutSource(_:)): item.state = layoutMode == .source ? .on : .off
        case #selector(layoutBoth(_:)): item.state = layoutMode == .both ? .on : .off; return doc.isTypesettable
        case #selector(layoutPages(_:)): item.state = layoutMode == .pages ? .on : .off; return doc.isTypesettable
        case #selector(toggleNumbers(_:)): item.state = source.text.showsNumbers ? .on : .off
        case #selector(toggleLive(_:)): item.state = Prefs.liveTypeset ? .on : .off
        case #selector(togglePDFBeside(_:)): item.state = Prefs.pdfBesideOnSave ? .on : .off
        case #selector(typesetNow(_:)), #selector(typesetFull(_:)): return doc.isTypesettable
        case #selector(exportPDF(_:)), #selector(printDocument(_:)), #selector(showInPDFAction(_:)),
             #selector(zoomInPages(_:)), #selector(zoomOutPages(_:)), #selector(fitPages(_:)):
            return preview.pdf.document != nil
        case #selector(showIssues(_:)), #selector(nextIssue(_:)): return last.map { !$0.issues.isEmpty } ?? false
        default: break
        }
        return true
    }

    /// Snapshot probe support.
    var lastResult: TypesetResult? { last }
}

/// A PDF opened to read: just the pages on the desk.
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let preview = PreviewPane()
    private let titleLabel = handLabel("", size: 16, bold: true)
    init(document: PDFReadDocument) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 980),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Theme.ink
        w.tabbingMode = .preferred
        w.setFrameAutosaveName("GalleyReader")
        titleLabel.stringValue = document.pdfURL?.lastPathComponent ?? "PDF"
        let tb = NSToolbar(identifier: "GalleyReaderToolbar")
        tb.delegate = self
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        let root = DeskView()
        w.contentView = root
        preview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor), preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.topAnchor.constraint(equalTo: root.topAnchor), preview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        if let u = document.pdfURL { preview.load(u) }
        shouldCascadeWindows = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.gTitle] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.gTitle] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = titleLabel
        return item
    }

    @objc func zoomInPages(_ s: Any?) { preview.pdf.zoomIn(s); preview.pdf.fitting = false }
    @objc func zoomOutPages(_ s: Any?) { preview.pdf.zoomOut(s); preview.pdf.fitting = false }
    @objc func fitPages(_ s: Any?) { preview.pdf.refit() }
    @objc func printDocument(_ sender: Any?) {
        guard let d = preview.pdf.document, let op = d.printOperation(for: document?.printInfo ?? .shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        op.runModal(for: window!, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

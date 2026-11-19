import AppKit
import PDFKit

/// The typeset pages, lying on the stone desk.
final class PreviewView: PDFView {
    /// Fit the page width until the person zooms; ⌘0 fits again.
    var fitting = true
    var onSyncEdit: ((Int, Double, Double) -> Void)?
    var onPageChange: (() -> Void)?
    private var refitting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0)
        autoScales = false
        pageShadowsEnabled = true
        backgroundColor = Theme.ink
        displaysAsBook = false
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func scaleChanged() { if !refitting { fitting = false } }
    @objc private func pageChanged() { onPageChange?() }

    override func layout() {
        super.layout()
        if fitting { refit() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = Theme.ink
    }

    func refit() {
        guard let page = document?.page(at: 0), bounds.width > 40 else { return }
        let w = page.bounds(for: displayBox).width
        let rot = page.rotation % 180 != 0 ? page.bounds(for: displayBox).height : w
        let target = max(0.1, (bounds.width - 72) / rot)
        refitting = true
        if abs(scaleFactor - target) > 0.002 { scaleFactor = target }
        refitting = false
        fitting = true
    }

    /// Swaps in a freshly typeset PDF, keeping the page and spot in view.
    func load(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else { return }
        var keep: (Int, NSPoint)?
        if let old = document, let page = currentPage, let top = topLeftInPage(page) {
            keep = (old.index(for: page), top)
        }
        let scale = scaleFactor
        let wasFitting = fitting
        refitting = true
        document = doc
        if wasFitting { refitting = false; refit() } else { scaleFactor = scale; refitting = false; fitting = false }
        if let (i, p) = keep, let page = doc.page(at: min(i, doc.pageCount - 1)) {
            go(to: PDFDestination(page: page, at: p))
        } else if let first = doc.page(at: 0) {
            layoutDocumentView()
            let box = first.bounds(for: displayBox)
            go(to: PDFDestination(page: first, at: NSPoint(x: box.minX, y: box.maxY + 18)))
        }
    }

    /// The point of `page` at the top-left of the visible area.
    private func topLeftInPage(_ page: PDFPage) -> NSPoint? {
        let topLeft = NSPoint(x: bounds.minX + 1, y: bounds.maxY - 1)
        guard let p = self.page(for: topLeft, nearest: true), p == page else {
            return currentDestination?.point
        }
        return convert(topLeft, to: page)
    }

    // MARK: SyncTeX

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let doc = document {
            let p = convert(event.locationInWindow, from: nil)
            if let page = page(for: p, nearest: true) {
                let q = convert(p, to: page)
                let box = page.bounds(for: .mediaBox)
                onSyncEdit?(doc.index(for: page), Double(q.x - box.minX), Double(box.maxY - q.y))
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Rect on `page` (in page space) for a SyncTeX spot in TeX's top-down coordinates.
    func pageRect(page: PDFPage, x: Double, y: Double, w: Double, h: Double) -> NSRect {
        let box = page.bounds(for: .mediaBox)
        let width = w > 2 ? w : min(220, box.width - x - 40)
        let height = max(h, 10)
        return NSRect(x: box.minX + CGFloat(x), y: box.maxY - CGFloat(y) - 2, width: CGFloat(width), height: CGFloat(height) + 2)
    }
}

/// The preview pane: the pages, the effects over them, and a taped page slip.
final class PreviewPane: NSView {
    let pdf = PreviewView()
    let effects = EffectsView()
    private let slip = PaperView(stock: Theme.slip, slip: true)
    private let pageLabel = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v in [pdf, effects] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        effects.flipsY = false

        empty.font = Theme.hand(17)
        empty.textColor = Theme.text3
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
        ])

        slip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slip)
        pageLabel.font = Theme.mono(11)
        pageLabel.textColor = Theme.text2
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        slip.addSubview(pageLabel)
        NSLayoutConstraint.activate([
            slip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            slip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            slip.heightAnchor.constraint(equalToConstant: 28),
            pageLabel.centerYAnchor.constraint(equalTo: slip.centerYAnchor, constant: 1),
            pageLabel.leadingAnchor.constraint(equalTo: slip.leadingAnchor, constant: 13),
            pageLabel.trailingAnchor.constraint(equalTo: slip.trailingAnchor, constant: -13),
        ])
        slip.tape(at: 0.5, width: 34, angle: -4, seed: 77)
        slip.frameCenterRotation = 0.8
        slip.isHidden = true
        pdf.onPageChange = { [weak self] in self?.updatePageLabel() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setEmpty(_ text: String?) {
        empty.stringValue = text ?? ""
        empty.isHidden = text == nil
    }

    func load(_ url: URL) {
        let first = pdf.document == nil
        pdf.load(url)
        setEmpty(nil)
        updatePageLabel()
        if first { Motion.rise(pdf.layer, by: 18, dur: 0.6) }
    }

    func updatePageLabel() {
        guard let doc = pdf.document, doc.pageCount > 0 else { slip.isHidden = true; return }
        let i = pdf.currentPage.map { doc.index(for: $0) + 1 } ?? 1
        pageLabel.stringValue = "p. \(i) of \(doc.pageCount)"
        if slip.isHidden { slip.isHidden = false; Motion.pop(slip.layer, from: 0.7, angle: 0.08) }
    }

    /// Scrolls to a SyncTeX spot and circles it in orange felt.
    func circle(page index: Int, x: Double, y: Double, w: Double, h: Double) {
        guard let doc = pdf.document, let page = doc.page(at: index) else { return }
        let r = pdf.pageRect(page: page, x: x, y: y, w: w, h: h)
        pdf.go(to: r.insetBy(dx: -40, dy: -120), on: page)
        layoutSubtreeIfNeeded()
        let vr = effects.convert(pdf.convert(r, from: page), from: pdf).insetBy(dx: -10, dy: -7)
        let ink = InkLayer()
        ink.shape = .loop
        ink.pen = Pen.felt.scaled(1.35)
        ink.ink = Theme.accent
        ink.owner = self
        ink.seed = UInt32.random(in: 1...1_000_000)
        ink.frame = vr
        effects.layer?.addSublayer(ink)
        ink.rebuild()
        ink.drawOn(dur: 0.55)
        let fade = Motion.anim("opacity", from: 1, to: 0, dur: 0.6, delay: 1.6)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        ink.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.enabled ? 2.3 * Motion.slow : 1.6)) { ink.removeFromSuperlayer() }
    }
}

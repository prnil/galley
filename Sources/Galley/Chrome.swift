import AppKit

/// Looseleaf tabs: words in hand-drawn boxes; the chosen one is filled with
/// highlighter yellow that soaks in while its outline draws on.
final class InkTabs: NSView {
    private(set) var selected: Int
    private let titles: [String]
    private var boxes: [InkLayer] = []
    private var labels: [NSTextField] = []
    var onChange: ((Int) -> Void)?

    init(_ titles: [String], selected: Int) {
        self.titles = titles
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for (i, t) in titles.enumerated() {
            let box = InkLayer()
            box.pen = Pen.fine.scaled(1.1)
            box.owner = self
            box.seed = Ink.seed("tab-\(t)")
            layer?.addSublayer(box)
            boxes.append(box)
            let l = NSTextField(labelWithString: t)
            l.font = Theme.hand(13.5)
            l.alignment = .center
            l.textColor = Theme.text
            addSubview(l)
            labels.append(l)
            _ = i
        }
        restyle(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var widths: [CGFloat] { labels.map { ceil($0.intrinsicContentSize.width) + 24 } }
    override var intrinsicContentSize: NSSize { NSSize(width: widths.reduce(0, +) + CGFloat(titles.count - 1) * 4, height: 28) }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, w) in widths.enumerated() {
            let r = NSRect(x: x, y: 0, width: w, height: bounds.height)
            boxes[i].frame = r.insetBy(dx: 1, dy: 1.5)
            let h = labels[i].intrinsicContentSize.height
            labels[i].frame = NSRect(x: r.minX, y: (bounds.height - h) / 2 - 1, width: w, height: h)
            x += w + 4
        }
        CATransaction.commit()
    }

    func select(_ i: Int, animated: Bool = true) {
        guard i != selected, i >= 0, i < titles.count else { return }
        selected = i
        restyle(animated: animated)
    }

    private func restyle(animated: Bool) {
        for (i, b) in boxes.enumerated() {
            let on = i == selected
            b.fill = on ? Theme.hi : nil
            b.ink = on ? Theme.text : Theme.rule
            labels[i].textColor = on ? Theme.text : Theme.text2
            if on && animated { b.drawOn(dur: 0.45); b.soak() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = boxes.firstIndex(where: { $0.frame.insetBy(dx: -2, dy: -3).contains(p) }) else { return }
        Motion.sink(layer)
        if i != selected {
            select(i)
            onChange?(i)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        boxes.forEach { $0.recolour() }
    }
}

/// How the last typeset went: a felt ring that boils while TeX works, then
/// a green tick, or a red cross when TeX stopped on errors.
final class StatusMark: NSView {
    enum State { case idle, working, ok, failed }
    private let ring = InkLayer()
    private var mark = CALayer()
    private var boilTimer: Timer?
    private(set) var state: State = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.shape = .loop
        ring.pen = Pen.fine.scaled(1.2)
        ring.ink = Theme.rule
        ring.owner = self
        ring.seed = 4242
        layer?.addSublayer(ring)
        layer?.addSublayer(mark)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: 3, dy: 3)
        CATransaction.commit()
    }

    func set(_ s: State) {
        guard s != state else { return }
        state = s
        boilTimer?.invalidate()
        boilTimer = nil
        mark.removeFromSuperlayer()
        mark = CALayer()
        layer?.addSublayer(mark)
        switch s {
        case .idle:
            ring.ink = Theme.rule
        case .working:
            ring.ink = Theme.accent
            ring.drawOn(dur: 0.4)
            // Boils while TeX runs: a step every 0.5 s, only while working.
            if Motion.enabled {
                boilTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.ring.boil() }
            }
        case .ok:
            ring.ink = Theme.green
            draw(tick: true, color: Theme.green)
        case .failed:
            ring.ink = Theme.clay
            draw(tick: false, color: Theme.clay)
            Motion.jolt(layer, amount: 2)
        }
    }

    private func draw(tick: Bool, color: NSColor) {
        let b = bounds.insetBy(dx: 8, dy: 8)
        let seed = UInt32.random(in: 1...100_000)
        var stroke: InkStroke
        if tick {
            let pts = Ink.line(CGPoint(x: b.minX, y: b.midY), CGPoint(x: b.minX + b.width * 0.38, y: b.minY), bow: 0.3, seed: seed)
                + Ink.line(CGPoint(x: b.minX + b.width * 0.38, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), bow: 0.5, seed: seed + 1)
            stroke = Ink.stroke(pts, pen: Pen.felt.scaled(1.1), seed: seed)
        } else {
            stroke = Ink.stroke(Ink.line(CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.minY), bow: 0.4, seed: seed), pen: Pen.felt.scaled(1.1), seed: seed)
                + Ink.stroke(Ink.line(CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), bow: 0.4, seed: seed + 9), pen: Pen.felt.scaled(1.1), seed: seed + 9)
        }
        let l = stroke.layer(color: Theme.cg(color, in: self), frame: bounds)
        mark.addSublayer(l)
        Ink.drawOn(l, stroke: stroke, dur: 0.35)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ring.recolour()
    }
}

/// A label in the hand.
func handLabel(_ s: String, size: CGFloat = 13, bold: Bool = false, color: NSColor = Theme.text) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = Theme.hand(size, bold: bold)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

/// The divider between source and pages: a pencil line on the desk.
final class PencilSplitView: NSSplitView {
    private let pencil = InkLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
        wantsLayer = true
        pencil.shape = .vline
        pencil.pen = Pen.fine
        pencil.ink = Theme.rule
        pencil.seed = 99
        pencil.owner = self
        layer?.addSublayer(pencil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var dividerThickness: CGFloat { 9 }
    /// Divider position as a fraction of the width, applied once the view has a size.
    var pendingFraction: CGFloat?
    override func drawDivider(in rect: NSRect) {
        Theme.ink.setFill()
        rect.fill()
    }
    override func layout() {
        super.layout()
        guard subviews.count > 1 else { return }
        let shown = subviews.filter { !$0.isHidden }
        if let f = pendingFraction, bounds.width > 100, shown.count > 1, let i = subviews.firstIndex(of: shown[0]) {
            pendingFraction = nil
            // The divider after the first visible pane (hidden panes sit at zero width before it).
            let d = subviews.firstIndex(of: shown[1])! - 1
            _ = i
            setPosition(floor(bounds.width * f), ofDividerAt: d)
        }
        let left = shown.first ?? subviews[0]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pencil.isHidden = shown.count < 2
        pencil.frame = NSRect(x: left.frame.maxX + 2, y: bounds.height * 0.08, width: 5, height: bounds.height * 0.84)
        pencil.zPosition = 10
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pencil.recolour()
    }
}

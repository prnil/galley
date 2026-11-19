import AppKit

// The Looseleaf desk kit: sheets of paper with tooth, washi tape, and ink
// shapes (boxes, loops, underlines) drawn with the pen in Ink.swift.

// MARK: Paper

/// A sheet of paper on the desk: stock colour, Looseleaf's texture tiles,
/// optional blue rules and a red margin, and a warm card shadow.
class PaperView: NSView {
    var stock: NSColor { didSet { needsDisplay = true } }
    var slipTexture = false
    /// Distance between blue rules (nil: plain paper) and where they start from the top.
    var ruleGap: CGFloat? { didSet { needsDisplay = true } }
    var ruleTop: CGFloat = 40
    /// x of the red margin line (nil: none).
    var margin: CGFloat? { didSet { needsDisplay = true } }
    var lifted = false { didSet { Theme.cardShadow(layer, lift: lifted) } }

    init(stock: NSColor = Theme.paperStock, slip: Bool = false) {
        self.stock = stock
        self.slipTexture = slip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        Theme.cardShadow(layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.fillPaper(bounds, stock: stock, slip: slipTexture)
        if let gap = ruleGap {
            Theme.ruleBlue.withAlphaComponent(0.8).setFill()
            var y = ruleTop
            while y < bounds.height - 4 {
                NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
                y += gap
            }
        }
        if let m = margin {
            Theme.ruleRed.setFill()
            NSRect(x: m, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Lays a strip of tape over this sheet's edge. `at` is the fraction
    /// along the top (0 = left, 1 = right).
    @discardableResult
    func tape(at: CGFloat, width: CGFloat = 54, angle: CGFloat? = nil, seed: UInt32) -> TapeView {
        var r = InkRandom(seed)
        let t = TapeView(seed: seed)
        t.translatesAutoresizingMaskIntoConstraints = false
        addSubview(t)
        NSLayoutConstraint.activate([
            t.widthAnchor.constraint(equalToConstant: width),
            t.heightAnchor.constraint(equalToConstant: 17),
            t.centerYAnchor.constraint(equalTo: topAnchor, constant: 1),
            NSLayoutConstraint(item: t, attribute: .centerX, relatedBy: .equal, toItem: self, attribute: .trailing,
                               multiplier: max(0.001, at), constant: at < 0.5 ? width * 0.25 : (at > 0.5 ? -width * 0.25 : 0)),
        ])
        t.frameCenterRotation = angle ?? ((r.next() - 0.5) * 10)
        return t
    }
}

/// Washi tape: half see-through, torn ends, a faint edge.
final class TapeView: NSView {
    private let seed: UInt32
    init(seed: UInt32) {
        self.seed = seed
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        var r = InkRandom(seed)
        let b = bounds
        let p = NSBezierPath()
        // Torn ends: small zigzags down each short side.
        let teeth = 5
        p.move(to: NSPoint(x: b.minX + 2 * r.next(), y: b.minY))
        p.line(to: NSPoint(x: b.maxX - 2 * r.next(), y: b.minY))
        for k in 1...teeth {
            let y = b.minY + b.height * CGFloat(k) / CGFloat(teeth)
            p.line(to: NSPoint(x: b.maxX - (k % 2 == 0 ? 0 : 2.5) * (0.5 + r.next()), y: y))
        }
        p.line(to: NSPoint(x: b.minX + 2 * r.next(), y: b.maxY))
        for k in stride(from: teeth - 1, through: 0, by: -1) {
            let y = b.minY + b.height * CGFloat(k) / CGFloat(teeth)
            p.line(to: NSPoint(x: b.minX + (k % 2 == 0 ? 0 : 2.5) * (0.5 + r.next()), y: y))
        }
        p.close()
        Theme.tape.setFill()
        p.fill()
        Theme.tapeEdge.setFill()
        NSRect(x: b.minX + 2, y: b.minY, width: b.width - 4, height: 0.75).fill()
        NSRect(x: b.minX + 2, y: b.maxY - 0.75, width: b.width - 4, height: 0.75).fill()
    }
}

/// The desk itself: flat stone.
final class DeskView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.ink.setFill()
        dirtyRect.fill()
    }
}

// MARK: Ink shapes for controls

/// A hand-drawn shape that fits its bounds: a box (with an optional solid
/// fill sitting inside the outline), a loop round the middle, an underline
/// along the bottom, or a line. Redraws when resized or re-coloured; can draw
/// itself on, and "boil" (redraw a few times with new seeds) like Looseleaf's hover.
final class InkLayer: CALayer {
    enum Shape { case box(radius: CGFloat), loop, underline, vline, hline }

    var shape: Shape = .box(radius: 2) { didSet { rebuild() } }
    var pen: Pen = .felt { didSet { rebuild() } }
    var seed: UInt32 = 1 { didSet { rebuild() } }
    var ink: NSColor = Theme.text { didSet { recolour() } }
    var fill: NSColor? { didSet { recolour() } }
    weak var owner: NSView? { didSet { recolour() } }

    private let fillLayer = CALayer()
    private var strokeHost = CALayer()
    private var stroke = InkStroke()
    private var builtSize = CGSize.zero
    private var boilStep = 0

    override init() {
        super.init()
        fillLayer.cornerRadius = 1.5
        addSublayer(fillLayer)
        addSublayer(strokeHost)
        masksToBounds = false
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSublayers() {
        super.layoutSublayers()
        if bounds.size != builtSize { rebuild() }
    }

    func rebuild() {
        builtSize = bounds.size
        guard bounds.width > 2, bounds.height > 0.5 else { return }
        let b = bounds
        let s = seed &+ UInt32(boilStep) &* 7919
        switch shape {
        case .box(let r):
            stroke = Ink.stroke(Ink.box(b.insetBy(dx: 1, dy: 1), radius: r, seed: s), pen: pen, seed: s)
        case .loop:
            stroke = Ink.stroke(Ink.loop(b, seed: s), pen: pen, seed: s)
        case .underline:
            stroke = Ink.stroke(Ink.line(CGPoint(x: b.minX, y: b.midY), CGPoint(x: b.maxX, y: b.midY + 0.6), bow: 1.2, seed: s), pen: pen, seed: s)
        case .vline:
            stroke = Ink.stroke(Ink.line(CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.midX, y: b.maxY), bow: 0.8, seed: s), pen: pen, seed: s)
        case .hline:
            stroke = Ink.stroke(Ink.line(CGPoint(x: b.minX, y: b.midY), CGPoint(x: b.maxX, y: b.midY), bow: 0.6, seed: s), pen: pen, seed: s)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = b.insetBy(dx: 2, dy: 2)
        strokeHost.removeFromSuperlayer()
        strokeHost = stroke.layer(color: Theme.cg(ink, in: owner), frame: b)
        addSublayer(strokeHost)
        recolour()
        CATransaction.commit()
    }

    func recolour() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = Theme.cg(ink, in: owner)
        for case let s as CAShapeLayer in strokeHost.sublayers ?? [] { s.fillColor = c }
        fillLayer.backgroundColor = fill.map { Theme.cg($0, in: owner) }
        fillLayer.isHidden = fill == nil
        CATransaction.commit()
    }

    /// The pen draws the shape, start to finish.
    func drawOn(dur: Double = 0.6, delay: Double = 0) {
        Ink.drawOn(strokeHost, stroke: stroke, dur: dur, delay: delay)
    }

    /// The fill soaks in from the left (Looseleaf's --ll-dur-soak, 0.52 s).
    func soak(delay: Double = 0) {
        guard Motion.enabled, fill != nil else { return }
        let a = Motion.anim("transform", from: Motion.value(scaleFromLeft(fillLayer, 0.02)), to: Motion.value(CATransform3DIdentity),
                            dur: 0.52, delay: delay, timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.12))
        a.fillMode = .backwards
        fillLayer.add(a, forKey: "soak")
    }

    /// Redraws three times with new seeds, then settles back (0.48 s).
    func boil() {
        guard Motion.enabled, boilStep == 0 else { return }
        for (i, step) in [1, 2, 3, 0].enumerated() {
            Motion.after(Double(i) * 0.12) { [weak self] in
                guard let self else { return }
                self.boilStep = step
                self.rebuild()
            }
        }
    }

    private func scaleFromLeft(_ l: CALayer, _ k: CGFloat) -> CATransform3D {
        let px = -l.anchorPoint.x * l.bounds.width + l.bounds.width * 0   // left edge, from the anchor
        var t = CATransform3DMakeTranslation(px, 0, 0)
        t = CATransform3DScale(t, k, 1, 1)
        return CATransform3DTranslate(t, -px, 0, 0)
    }
}

/// A short pencil line between groups of controls.
final class InkDivider: NSView {
    private let ink = InkLayer()
    private let vertical: Bool
    init(vertical: Bool = true, length: CGFloat = 18) {
        self.vertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        ink.shape = vertical ? .vline : .hline
        ink.pen = Pen.fine
        ink.ink = Theme.rule
        ink.owner = self
        ink.seed = UInt32.random(in: 1...100_000)
        layer?.addSublayer(ink)
        translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            widthAnchor.constraint(equalToConstant: 3).isActive = true
            heightAnchor.constraint(equalToConstant: length).isActive = true
        } else {
            heightAnchor.constraint(equalToConstant: 3).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { vertical ? NSSize(width: 3, height: 18) : NSSize(width: NSView.noIntrinsicMetric, height: 3) }
    override func layout() {
        super.layout()
        ink.frame = bounds
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.recolour()
    }
}

/// The stone band behind the floating toolbar, with a soft warm shadow on
/// its lower edge. A plain layer, not a view: as a view (opaque or not, with
/// or without its shadow) macOS 26 stopped drawing the pages whenever it
/// showed under the toolbar (bisected with the tbfade probe, 19 Nov).
final class ToolbarBand: CALayer {
    weak var owner: NSView?
    override init() {
        super.init()
        shadowColor = Theme.shade.cgColor
        shadowOpacity = 0.18
        shadowRadius = 6
        shadowOffset = CGSize(width: 0, height: -3)
        zPosition = 1                      // over the pages, under the tool strip (2) and effects (3)
        recolour()
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    func recolour() { backgroundColor = Theme.cg(Theme.ink, in: owner) }
    func place(_ r: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = r
        shadowPath = CGPath(rect: bounds, transform: nil)
        CATransaction.commit()
    }
    var alphaValue: CGFloat { CGFloat(opacity) }
    func fade(_ on: Bool, duration: Double) {
        let from = presentation()?.opacity ?? opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = on ? 1 : 0
        CATransaction.commit()
        guard duration > 0 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = opacity
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        add(a, forKey: "fade")
    }
}

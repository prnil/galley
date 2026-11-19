import AppKit

// MARK: Buttons

/// Pads the button's contents inside its hand-drawn box, so the icon and
/// word sit centred instead of hugging the left edge.
final class InkButtonCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { super.drawingRect(forBounds: rect.insetBy(dx: 10, dy: 3)) }
    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let s = super.cellSize(forBounds: rect)
        return NSSize(width: s.width + 20, height: max(s.height + 6, 26))
    }
}

/// A Looseleaf button: a word (and icon) in a box drawn with a felt pen.
/// The outline boils under the pointer; a click sinks it by 1 pt.
final class InkButton: NSButton {
    override class var cellClass: AnyClass? { get { InkButtonCell.self } set {} }
    private let box = InkLayer()
    private var hovering = false {
        didSet {
            box.ink = hovering ? Theme.text : Theme.text2
            if hovering { box.boil() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUpBox()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setUpBox() {
        wantsLayer = true
        layer?.masksToBounds = false
        box.pen = Pen.fine.scaled(1.15)
        box.ink = Theme.text2
        box.owner = self
        box.seed = UInt32.random(in: 1...1_000_000)
        layer?.insertSublayer(box, at: 0)
    }

    override var title: String {
        didSet { if font?.familyName != Theme.hand(12).familyName { font = Theme.hand(13) } }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = bounds.insetBy(dx: 1, dy: 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        box.recolour()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        Motion.sink(layer)
        super.mouseDown(with: event)
    }
}

/// Pads a start-screen button's word and icon evenly inside its box (the
/// size override this replaced added the room on one side only, so icons
/// sat on the edge of the hand-drawn box).
final class InkLinkCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { super.drawingRect(forBounds: rect.insetBy(dx: 15, dy: 6)) }
    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let s = super.cellSize(forBounds: rect)
        return NSSize(width: s.width + 30, height: s.height + 14)
    }
}

/// The welcome window's buttons, Looseleaf style: the main one filled with
/// terracotta marker inside an ink outline, the other outlined on paper.
/// The arrow nudges forward under the pointer.
final class InkLink: NSButton {
    override class var cellClass: AnyClass? { get { InkLinkCell.self } set {} }
    private let box = InkLayer()
    private let color: NSColor

    init(_ title: String, symbol: String?, color: NSColor, size: CGFloat, target: AnyObject?, action: Selector, filled: Bool = false) {
        self.color = color
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = Theme.hand(size)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: Theme.text])
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = .imageTrailing
            symbolConfiguration = .init(pointSize: size - 3, weight: .medium)
            contentTintColor = Theme.text
        }
        wantsLayer = true
        layer?.masksToBounds = false
        box.pen = Pen.felt
        box.ink = Theme.text
        box.fill = filled ? Theme.accent : Theme.slip
        box.owner = self
        box.seed = Ink.seed("link-\(title)")
        layer?.insertSublayer(box, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        box.recolour()
    }

    func drawOn(delay: Double) {
        box.drawOn(dur: 0.6, delay: delay)
        box.soak(delay: delay + 0.25)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { box.boil(); tilt(true) }
    override func mouseExited(with event: NSEvent) { tilt(false) }
    override func mouseDown(with event: NSEvent) {
        Motion.sink(layer)
        super.mouseDown(with: event)
    }

    private func tilt(_ on: Bool) {
        guard let l = layer, Motion.enabled else { return }
        let to = on ? Motion.about(l, angle: -0.9 * .pi / 180, dy: 1) : CATransform3DIdentity
        let from = l.presentation()?.transform ?? l.transform
        l.transform = to
        l.add(Motion.spring("transform", from: Motion.value(from), to: Motion.value(to), damping: 15, stiffness: 380), forKey: "tilt")
    }
}

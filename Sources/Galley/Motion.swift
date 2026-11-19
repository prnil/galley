import AppKit
import QuartzCore

/// Galley's animation kit. Everything here is Core Animation: the window
/// server runs it on the GPU, and nothing runs between actions, so Galley
/// stays near zero CPU when idle. Effects are one-shot, started by something
/// the person did, and removed when they finish.
enum Motion {
    // MARK: On or off

    /// Off with Reduce Motion, with View › Animations off, and for the
    /// self-test, snapshots and bench (unless a probe turns it on to film it).
    static var enabled: Bool {
        if Prefs.probing && !forceOn { return false }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        return userSetting
    }

    static var userSetting: Bool {
        get {
            UserDefaults.standard.register(defaults: ["GalleyAnimations": true])
            return UserDefaults.standard.bool(forKey: "GalleyAnimations")
        }
        set { UserDefaults.standard.set(newValue, forKey: "GalleyAnimations") }
    }

    /// Probe support: `motion` turns effects on in a snapshot run, `slow=4` films them.
    static var forceOn = false
    static var slow: Double = 1

    // MARK: Curves

    /// Arrives, overshoots a touch, settles: the house curve for things landing.
    static let backOut = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.85, 0.35)
    static let inOut = CAMediaTimingFunction(name: .easeInEaseOut)

    // MARK: Animation builders

    static func anim(_ key: String, from: Any?, to: Any?, dur: Double, delay: Double = 0,
                     timing: CAMediaTimingFunction = easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = dur * slow
        a.timingFunction = timing
        if delay > 0 { a.beginTime = CACurrentMediaTime() + delay * slow; a.fillMode = .backwards }
        return a
    }

    static func spring(_ key: String, from: Any?, to: Any?, damping: CGFloat = 14, stiffness: CGFloat = 260,
                       delay: Double = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.damping = damping
        a.stiffness = stiffness
        a.mass = 1
        a.duration = a.settlingDuration
        a.speed = Float(1 / slow)
        if delay > 0 { a.beginTime = CACurrentMediaTime() + delay * slow; a.fillMode = .backwards }
        return a
    }

    static func value(_ t: CATransform3D) -> NSValue { NSValue(caTransform3D: t) }

    /// A transform about the layer's centre, whatever its anchor point
    /// (AppKit gives view layers an anchor of 0,0).
    static func about(_ layer: CALayer, scale s: CGFloat = 1, angle: CGFloat = 0, dx: CGFloat = 0, dy: CGFloat = 0) -> CATransform3D {
        let cx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let cy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var t = CATransform3DMakeTranslation(cx + dx, cy + dy, 0)
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    static func after(_ seconds: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * slow, execute: f)
    }

    // MARK: Small gestures on any layer

    /// Springs in from `scale` (and optionally rises `dy` points).
    static func pop(_ layer: CALayer?, from scale: CGFloat = 0.8, dy: CGFloat = 0, angle: CGFloat = 0, delay: Double = 0,
                    damping: CGFloat = 12) {
        guard enabled, let layer else { return }
        layer.add(spring("transform", from: value(about(layer, scale: scale, angle: angle, dy: dy)),
                         to: value(CATransform3DIdentity), damping: damping, delay: delay), forKey: "galleyPop")
        if delay > 0 || scale < 0.6 {
            layer.add(anim("opacity", from: 0, to: 1, dur: 0.18, delay: delay), forKey: "galleyPopFade")
        }
    }

    /// A quick squash and release, for clicks.
    static func press(_ layer: CALayer?) {
        guard enabled, let layer else { return }
        let k = CAKeyframeAnimation(keyPath: "transform")
        k.values = [1, 0.86, 1.06, 0.98, 1].map { value(about(layer, scale: $0)) }
        k.keyTimes = [0, 0.25, 0.55, 0.8, 1]
        k.duration = 0.38 * slow
        k.timingFunction = inOut
        layer.add(k, forKey: "galleyPress")
    }

    /// Looseleaf's press: the control sinks 1 pt for 90 ms and comes back.
    static func sink(_ layer: CALayer?) {
        guard enabled, let layer else { return }
        let k = CAKeyframeAnimation(keyPath: "transform")
        k.values = [CATransform3DIdentity, CATransform3DMakeTranslation(0, -1, 0), CATransform3DIdentity].map(value)
        k.keyTimes = [0, 0.4, 1]
        k.duration = 0.22 * slow
        layer.add(k, forKey: "galleySink")
    }

    /// Rises in from below while fading in: lists, rows and cards arriving.
    static func rise(_ layer: CALayer?, by dy: CGFloat = 14, delay: Double = 0, dur: Double = 0.5) {
        guard enabled, let layer else { return }
        layer.add(anim("transform", from: value(about(layer, dy: -dy)), to: value(CATransform3DIdentity), dur: dur, delay: delay), forKey: "galleyRise")
        layer.add(anim("opacity", from: 0, to: 1, dur: dur * 0.7, delay: delay, timing: inOut), forKey: "galleyRiseFade")
    }

    /// A small shake, as if something landed hard.
    static func jolt(_ layer: CALayer?, amount: CGFloat = 3, delay: Double = 0) {
        guard enabled, let layer else { return }
        let k = CAKeyframeAnimation(keyPath: "transform.translation.y")
        k.values = [0, -amount, amount * 0.6, -amount * 0.3, 0]
        k.duration = 0.28 * slow
        k.isAdditive = true
        if delay > 0 { k.beginTime = CACurrentMediaTime() + delay * slow }
        layer.add(k, forKey: "galleyJolt")
    }

    /// The SF Symbol in an image view does its bounce.
    static func bounce(_ iv: NSImageView?) {
        guard enabled, let iv else { return }
        iv.addSymbolEffect(.bounce, options: .nonRepeating)
    }

    // MARK: Ink effects drawn on an effects layer

    /// An ink ring spreading from `p`.
    static func ripple(at p: CGPoint, in host: CALayer, color: CGColor, radius: CGFloat = 34, width: CGFloat = 2, delay: Double = 0) {
        guard enabled else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.position = p
        ring.fillColor = nil
        ring.strokeColor = color
        ring.lineWidth = width
        ring.opacity = 0
        host.addSublayer(ring)
        let grow = anim("transform.scale", from: 0.15, to: 1, dur: 0.55, delay: delay)
        let fade = anim("opacity", from: 0.9, to: 0, dur: 0.55, delay: delay, timing: easeOut)
        let thin = anim("lineWidth", from: width * 2.5, to: width * 0.3, dur: 0.55, delay: delay)
        ring.add(grow, forKey: nil)
        ring.add(fade, forKey: nil)
        ring.add(thin, forKey: nil)
        after(delay + 0.6) { ring.removeFromSuperlayer() }
    }

    /// Specks of ink flying out from `p`.
    static func burst(at p: CGPoint, in host: CALayer, colors: [CGColor], count: Int = 9, distance: CGFloat = 38,
                      size: CGFloat = 4, delay: Double = 0) {
        guard enabled, !colors.isEmpty else { return }
        for i in 0..<count {
            let dot = CALayer()
            let s = size * CGFloat.random(in: 0.6...1.3)
            dot.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            dot.cornerRadius = s / 2
            dot.backgroundColor = colors[i % colors.count]
            dot.position = p
            dot.opacity = 0
            host.addSublayer(dot)
            let angle = CGFloat(i) / CGFloat(count) * .pi * 2 + CGFloat.random(in: -0.3...0.3)
            let d = distance * CGFloat.random(in: 0.6...1.15)
            let end = CGPoint(x: p.x + cos(angle) * d, y: p.y + sin(angle) * d - CGFloat.random(in: 0...8))
            let dur = Double.random(in: 0.42...0.6)
            dot.add(anim("position", from: NSValue(point: p), to: NSValue(point: end), dur: dur, delay: delay), forKey: nil)
            dot.add(anim("opacity", from: 1, to: 0, dur: dur, delay: delay, timing: easeIn), forKey: nil)
            dot.add(anim("transform.scale", from: 1, to: 0.3, dur: dur, delay: delay), forKey: nil)
            after(delay + dur + 0.05) { dot.removeFromSuperlayer() }
        }
    }

    // MARK: Pictures of views

    static func snapshot(_ v: NSView) -> CGImage? {
        guard v.bounds.width > 0, v.bounds.height > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    /// A free-standing copy of `v` on `host`'s layer, centred where `v` is.
    static func ghost(of v: NSView, on host: EffectsView) -> CALayer? {
        guard let img = snapshot(v) else { return nil }
        let r = host.convert(v.bounds, from: v)
        let g = CALayer()
        g.contents = img
        g.contentsScale = host.window?.backingScaleFactor ?? 2
        g.bounds = CGRect(origin: .zero, size: r.size)
        g.position = CGPoint(x: r.midX, y: r.midY)
        host.layer?.addSublayer(g)
        return g
    }

    static func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) -> CGImage? {
        let conf = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(conf) else { return nil }
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    static func textLayer(_ s: String, font: NSFont, color: CGColor, scale: CGFloat) -> CATextLayer {
        let t = CATextLayer()
        t.string = s
        t.font = font
        t.fontSize = font.pointSize
        t.foregroundColor = color
        t.contentsScale = scale
        t.alignmentMode = .left
        let size = (s as NSString).size(withAttributes: [.font: font])
        t.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
        return t
    }
}

/// A see-through layer laid over a view for effects. It never takes clicks.
final class EffectsView: NSView {
    var flipsY = false
    override var isFlipped: Bool { flipsY }
    /// The toast showing now, replaced by the next one.
    fileprivate var toast: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: The save seal

    /// An amber wax seal stamps down at `p`, a tick writes itself, a word
    /// slides out beside it, then it all lifts away.
    func seal(at p: CGPoint, word: String) {
        guard Motion.enabled, let host = layer else { return }
        let amber = Theme.cg(Theme.accent, in: self)
        let inkColor = Theme.cg(Theme.ink, in: self)
        let box = CALayer()
        box.bounds = CGRect(x: 0, y: 0, width: 54, height: 54)
        box.position = p
        host.addSublayer(box)

        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: CGRect(x: 7, y: 7, width: 40, height: 40), transform: nil)
        disc.fillColor = amber
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.35
        disc.shadowRadius = 8
        disc.shadowOffset = CGSize(width: 0, height: -3)
        // A scalloped rim, like pressed wax.
        let rim = CAShapeLayer()
        let rp = CGMutablePath()
        for i in 0..<14 {
            let a = CGFloat(i) / 14 * .pi * 2
            rp.addEllipse(in: CGRect(x: 27 + cos(a) * 21 - 4, y: 27 + sin(a) * 21 - 4, width: 8, height: 8))
        }
        rim.path = rp
        rim.fillColor = amber
        let tick = CAShapeLayer()
        let tp = CGMutablePath()
        tp.move(to: CGPoint(x: 18, y: 27))
        tp.addLine(to: CGPoint(x: 24.5, y: 20.5))
        tp.addLine(to: CGPoint(x: 37, y: 34))
        tick.path = tp
        tick.fillColor = nil
        tick.strokeColor = inkColor
        tick.lineWidth = 3.4
        tick.lineCap = .round
        tick.lineJoin = .round
        tick.strokeEnd = 0
        for l in [rim, disc, tick] as [CALayer] { box.addSublayer(l) }

        let label = Motion.textLayer(word, font: Theme.serif(16, .semibold, italic: true), color: amber, scale: scale)
        label.position = CGPoint(x: p.x - 34 - label.bounds.width / 2, y: p.y - 1)
        label.opacity = 0
        host.addSublayer(label)

        // Stamp down: big, tilted and see-through, then hard onto the page.
        box.add(Motion.anim("transform", from: Motion.value(Motion.about(box, scale: 2.1, angle: -0.5)),
                            to: Motion.value(CATransform3DIdentity), dur: 0.26, timing: Motion.easeIn), forKey: nil)
        box.add(Motion.anim("opacity", from: 0, to: 1, dur: 0.12), forKey: nil)
        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1, 0.9, 1.04, 1]
        squash.duration = 0.3 * Motion.slow
        squash.beginTime = CACurrentMediaTime() + 0.26 * Motion.slow
        squash.isAdditive = false
        box.add(squash, forKey: "squash")
        Motion.ripple(at: p, in: host, color: amber, radius: 44, width: 1.6, delay: 0.26)
        Motion.burst(at: p, in: host, colors: [amber, Theme.cg(Theme.sage, in: self)], count: 10, distance: 46, delay: 0.26)
        let draw = Motion.anim("strokeEnd", from: 0, to: 1, dur: 0.3, delay: 0.34, timing: Motion.inOut)
        draw.fillMode = .both
        draw.isRemovedOnCompletion = false
        tick.add(draw, forKey: nil)
        label.add(Motion.anim("opacity", from: 0, to: 1, dur: 0.3, delay: 0.42), forKey: nil)
        label.add(Motion.anim("transform.translation.x", from: 14, to: 0, dur: 0.45, delay: 0.42), forKey: nil)
        label.opacity = 1

        // Lift away.
        let leave = 1.7
        for l in [box, label] {
            let up = Motion.anim("transform.translation.y", from: 0, to: 16, dur: 0.4, delay: leave, timing: Motion.easeIn)
            up.isAdditive = true
            up.fillMode = .forwards
            up.isRemovedOnCompletion = false
            l.add(up, forKey: "leaveUp")
            let fade = Motion.anim("opacity", from: 1, to: 0, dur: 0.4, delay: leave, timing: Motion.easeIn)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            l.add(fade, forKey: "leaveFade")
        }
        Motion.after(leave + 0.45) { box.removeFromSuperlayer(); label.removeFromSuperlayer() }
    }

    // MARK: Toasts

    /// A short message at `p` (its centre): an icon that turns `spin`
    /// radians, and a word or two. One toast at a time.
    func toast(at p: CGPoint, symbol: String?, text: String, spin: CGFloat = 0, big: Bool = false, hold: Double = 0.9) {
        guard Motion.enabled, let host = layer else { return }
        toast?.removeFromSuperlayer()
        let font = big ? Theme.hand(30, bold: true) : Theme.hand(15)
        let fg = Theme.cg(Theme.text, in: self)
        let label = Motion.textLayer(text, font: font, color: fg, scale: scale)
        var icon: CALayer?
        if let symbol, let img = Motion.symbolImage(symbol, size: big ? 22 : 13, color: Theme.accent) {
            let l = CALayer()
            l.contents = img
            l.contentsScale = scale
            l.contentsGravity = .resizeAspect
            l.bounds = CGRect(x: 0, y: 0, width: big ? 26 : 16, height: big ? 26 : 16)
            icon = l
        }
        let padX: CGFloat = big ? 26 : 18
        let gap: CGFloat = icon == nil ? 0 : 8
        let w = padX * 2 + (icon?.bounds.width ?? 0) + gap + label.bounds.width
        let h: CGFloat = big ? 62 : 38
        // A slip of Looseleaf paper, taped down, with the warm card shadow.
        let bg = CALayer()
        bg.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        bg.position = p
        bg.cornerRadius = 1
        bg.backgroundColor = Theme.cg(Theme.slip, in: self)
        if let tile = Theme.slipTile {
            let tex = CALayer()
            tex.frame = bg.bounds
            tex.backgroundColor = Theme.cg(tile, in: self)
            bg.addSublayer(tex)
        }
        bg.shadowColor = Theme.shade.cgColor
        bg.shadowOpacity = 0.28
        bg.shadowRadius = 8
        bg.shadowOffset = CGSize(width: 0, height: -5)
        let tape = CALayer()
        tape.bounds = CGRect(x: 0, y: 0, width: min(52, w * 0.4), height: 15)
        tape.position = CGPoint(x: w / 2, y: h)
        tape.backgroundColor = Theme.cg(Theme.tape, in: self)
        tape.borderColor = Theme.cg(Theme.tapeEdge, in: self)
        tape.borderWidth = 0.5
        tape.transform = CATransform3DMakeRotation(CGFloat.random(in: -0.09...0.09), 0, 0, 1)
        tape.zPosition = 1
        bg.addSublayer(tape)
        var x = padX
        if let icon {
            icon.position = CGPoint(x: x + icon.bounds.width / 2, y: h / 2)
            bg.addSublayer(icon)
            x += icon.bounds.width + gap
            if spin != 0 {
                icon.add(Motion.anim("transform.rotation.z", from: -spin, to: 0, dur: 0.6, timing: Motion.backOut), forKey: nil)
            }
        }
        label.position = CGPoint(x: x + label.bounds.width / 2, y: h / 2)
        bg.addSublayer(label)
        host.addSublayer(bg)
        toast = bg
        bg.add(Motion.spring("transform", from: Motion.value(Motion.about(bg, scale: 0.7, dy: -10)), to: Motion.value(CATransform3DIdentity), damping: 15), forKey: nil)
        bg.add(Motion.anim("opacity", from: 0, to: 1, dur: 0.16), forKey: nil)
        let fade = Motion.anim("opacity", from: 1, to: 0, dur: 0.3, delay: hold, timing: Motion.easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        bg.add(fade, forKey: "leave")
        Motion.after(hold + 0.35) { [weak self] in
            bg.removeFromSuperlayer()
            if self?.toast === bg { self?.toast = nil }
        }
    }
}

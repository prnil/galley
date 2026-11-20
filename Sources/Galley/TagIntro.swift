import AppKit
import QuartzCore

/// The hero moment when Pair mode starts: a ring drawn in felt pen fills the
/// screen, the author's hand (blue ink) and Claude's hand (marker orange)
/// come in from the corners and tag each other in the middle, and
/// "Pair mode activated" is written under it. About 2.8 seconds, one shot,
/// skipped when animations are off; a click ends it early.
enum TagIntro {
    /// The window while it plays (probes capture it).
    private(set) static var window: NSWindow?

    static func play(on screen: NSScreen?) {
        guard Motion.enabled, window == nil, let screen = screen ?? NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let stage = Stage(frame: NSRect(origin: .zero, size: screen.frame.size))
        w.contentView = stage
        stage.onSkip = { finish(fast: true) }
        w.orderFrontRegardless()
        window = w
        stage.run()
        Motion.after(2.45) { finish(fast: false) }
    }

    private static func finish(fast: Bool) {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = (fast ? 0.15 : 0.4) * Motion.slow
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    /// The ring, the hands and the words, all Core Animation.
    final class Stage: NSView {
        var onSkip: (() -> Void)?
        override var isFlipped: Bool { false }
        override func mouseDown(with event: NSEvent) { onSkip?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func run() {
            wantsLayer = true
            guard let host = layer else { return }
            let W = bounds.width, H = bounds.height
            let cx = W / 2, cy = H * 0.46
            let scale = window?.backingScaleFactor ?? 2
            let unit = min(W, H)

            // The desk comes over everything.
            let desk = CALayer()
            desk.frame = bounds
            desk.backgroundColor = Theme.cg(Theme.ink, in: self)
            host.addSublayer(desk)
            desk.add(Motion.anim("opacity", from: 0, to: 1, dur: 0.25), forKey: nil)

            // The ring: two corner posts and three ropes, drawn on in turn.
            let left = W * 0.1, right = W * 0.9
            let ropeYs = [cy - unit * 0.17, cy - unit * 0.07, cy + unit * 0.03]
            for (i, x) in [left, right].enumerated() {
                let post = InkLayer()
                post.shape = .vline
                post.pen = Pen.brush.scaled(2.2)
                post.ink = Theme.text
                post.owner = self
                post.seed = 700 + UInt32(i)
                post.frame = CGRect(x: x - 8, y: ropeYs[0] - unit * 0.08, width: 16, height: ropeYs[2] - ropeYs[0] + unit * 0.14)
                host.addSublayer(post)
                post.rebuild()
                post.drawOn(dur: 0.3, delay: 0.05)
            }
            for (i, y) in ropeYs.enumerated() {
                let rope = InkLayer()
                rope.shape = .hline
                rope.pen = Pen.felt.scaled(2.1)
                rope.ink = [Theme.clay, Theme.text2, Theme.sage][i]
                rope.owner = self
                rope.seed = 810 + UInt32(i)
                rope.frame = CGRect(x: left, y: y - 6, width: right - left, height: 12)
                host.addSublayer(rope)
                rope.rebuild()
                rope.drawOn(dur: 0.42, delay: 0.12 + Double(i) * 0.07)
            }

            // The two hands, each with its name, sweep in and slap in the middle.
            let size = unit * 0.2
            let contact = 0.95
            func corner(_ name: String, color: NSColor, fromLeft: Bool) -> CALayer {
                let box = CALayer()
                let hand = CALayer()
                if let img = Motion.symbolImage("hand.raised.fill", size: size, weight: .bold, color: Theme.resolved(color, in: self)) {
                    hand.contents = img
                    let r = CGFloat(img.width) / CGFloat(max(img.height, 1))
                    hand.bounds = CGRect(x: 0, y: 0, width: size * 1.25 * r, height: size * 1.25)
                }
                hand.contentsScale = scale
                var t = CATransform3DMakeRotation(fromLeft ? -0.58 : 0.58, 0, 0, 1)
                if !fromLeft { t = CATransform3DScale(t, -1, 1, 1) }
                hand.transform = t
                let label = Motion.textLayer(name, font: Theme.hand(unit * 0.045, bold: true), color: Theme.cg(color, in: self), scale: scale)
                box.bounds = CGRect(x: 0, y: 0, width: hand.bounds.width, height: hand.bounds.height + label.bounds.height + 10)
                // Name above, on the outer side; the hand below it.
                hand.position = CGPoint(x: box.bounds.midX, y: hand.bounds.height / 2)
                label.position = CGPoint(x: box.bounds.midX + (fromLeft ? -size * 0.55 : size * 0.55), y: box.bounds.maxY - label.bounds.height / 2)
                box.addSublayer(hand)
                box.addSublayer(label)
                let rest = CGPoint(x: cx + (fromLeft ? -1 : 1) * hand.bounds.width * 0.27, y: cy + box.bounds.height * 0.12)
                let start = CGPoint(x: fromLeft ? -box.bounds.width : W + box.bounds.width, y: rest.y - unit * 0.12)
                // Palms meet and press in past each other at the slap, then spring back to fingertips touching.
                let hit = CGPoint(x: rest.x + (fromLeft ? 1 : -1) * hand.bounds.width * 0.1, y: rest.y + 6)
                let recoil = CGPoint(x: rest.x + (fromLeft ? -1 : 1) * unit * 0.035, y: rest.y + 4)
                box.position = rest
                let k = CAKeyframeAnimation(keyPath: "position")
                k.values = [start, hit, recoil, rest].map { NSValue(point: $0) }
                k.keyTimes = [0, 0.58, 0.78, 1]
                k.timingFunctions = [Motion.easeIn, Motion.easeOut, Motion.inOut]
                k.duration = 0.85 * Motion.slow
                k.beginTime = CACurrentMediaTime() + (contact - 0.85 * 0.58) * Motion.slow
                k.fillMode = .backwards
                box.add(k, forKey: "sweep")
                return box
            }
            let you = corner("you", color: Theme.sage, fromLeft: true)
            let claude = corner("Claude", color: Theme.accent, fromLeft: false)
            host.addSublayer(you)
            host.addSublayer(claude)

            // The tag: ink flies, rings spread, the screen takes the hit.
            let slap = CGPoint(x: cx, y: cy + you.bounds.height * 0.42)
            let inks = [Theme.accent, Theme.sage, Theme.hi, Theme.clay].map { Theme.cg($0, in: self) }
            Motion.burst(at: slap, in: host, colors: inks, count: 22, distance: unit * 0.2, size: unit * 0.012, delay: contact)
            Motion.ripple(at: slap, in: host, color: inks[0], radius: unit * 0.16, width: 4, delay: contact)
            Motion.ripple(at: slap, in: host, color: inks[1], radius: unit * 0.24, width: 3, delay: contact + 0.09)
            Motion.after(contact) { [weak self] in Motion.jolt(self?.layer, amount: unit * 0.012) }

            let tag = Motion.textLayer("TAG!", font: Theme.hand(unit * 0.11, bold: true), color: inks[0], scale: scale)
            tag.position = CGPoint(x: cx, y: slap.y + you.bounds.height * 0.62)
            tag.opacity = 0
            host.addSublayer(tag)
            let tagIn = CAKeyframeAnimation(keyPath: "transform")
            tagIn.values = [0.2, 1.25, 0.95, 1, 1.08].map { Motion.value(CATransform3DRotate(CATransform3DMakeScale($0, $0, 1), -0.12, 0, 0, 1)) }
            tagIn.keyTimes = [0, 0.25, 0.45, 0.6, 1]
            let tagFade = CAKeyframeAnimation(keyPath: "opacity")
            tagFade.values = [0, 1, 1, 0]
            tagFade.keyTimes = [0, 0.1, 0.7, 1]
            for a in [tagIn, tagFade] as [CAKeyframeAnimation] {
                a.duration = 0.9 * Motion.slow
                a.beginTime = CACurrentMediaTime() + (contact + 0.02) * Motion.slow
                a.fillMode = .both
                a.isRemovedOnCompletion = false
                tag.add(a, forKey: nil)
            }

            // The words, written under the ring, with a highlighter swipe.
            let title = Motion.textLayer("Pair mode activated", font: Theme.hand(unit * 0.07, bold: true), color: Theme.cg(Theme.text, in: self), scale: scale)
            title.position = CGPoint(x: cx, y: ropeYs[0] - unit * 0.17)
            host.addSublayer(title)
            let swipe = InkLayer()
            swipe.shape = .underline
            swipe.pen = Pen.brush.scaled(2.4)
            swipe.ink = Theme.hi
            swipe.owner = self
            swipe.seed = 990
            swipe.frame = CGRect(x: title.frame.minX - 6, y: title.frame.minY - 2, width: title.bounds.width + 12, height: 14)
            host.insertSublayer(swipe, below: title)
            swipe.rebuild()
            swipe.drawOn(dur: 0.4, delay: contact + 0.5)
            title.add(Motion.spring("transform", from: Motion.value(CATransform3DMakeTranslation(0, -unit * 0.03, 0)),
                                    to: Motion.value(CATransform3DIdentity), damping: 11, delay: contact + 0.3), forKey: nil)
            let fade = Motion.anim("opacity", from: 0, to: 1, dur: 0.25, delay: contact + 0.3)
            title.add(fade, forKey: nil)
        }
    }
}

extension Theme {
    /// A dynamic colour pinned to `view`'s appearance (SF Symbol palettes do not follow it).
    static func resolved(_ c: NSColor, in view: NSView?) -> NSColor {
        NSColor(cgColor: cg(c, in: view)) ?? c
    }
}

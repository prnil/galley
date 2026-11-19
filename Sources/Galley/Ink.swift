import AppKit

// A compact Swift port of Looseleaf's felt-pen engine (src/lib/ink/pen.ts,
// MIT, Looseleaf contributors). A stroke is a filled ribbon, not a line:
// resampled, wobbled by seeded noise, wider where the pen is slow (at the
// ends and on tight turns), with a faint bleed halo, a darker core and ink
// pools where the pen sat. The same seed always draws the same stroke.

/// Seeded random numbers (mulberry32).
struct InkRandom {
    private var state: UInt32
    init(_ seed: UInt32) { state = seed &* 2_654_435_761 &+ 0x9E37 }
    mutating func next() -> CGFloat {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return CGFloat(t ^ (t >> 14)) / 4_294_967_296
    }
    mutating func fork() -> InkRandom { InkRandom(UInt32(next() * 4_294_967_295)) }
}

/// Smooth 1-D value noise in -1...1 along a stroke of length `length`.
struct InkNoise {
    private let knots: [CGFloat]
    private let wl: CGFloat
    init(_ rng: inout InkRandom, length: CGFloat, wavelength: CGFloat) {
        wl = max(0.5, wavelength)
        knots = (0..<(Int(length / wl) + 3)).map { _ in rng.next() * 2 - 1 }
    }
    func callAsFunction(_ s: CGFloat) -> CGFloat {
        let x = max(0, s) / wl
        let i = min(Int(x), knots.count - 2)
        var t = x - CGFloat(i)
        t = t * t * (3 - 2 * t)
        return knots[i] + (knots[i + 1] - knots[i]) * t
    }
}

/// A pen, with Looseleaf's numbers (src/lib/ink/pens.ts).
struct Pen {
    var W: CGFloat = 1.7
    var alpha: CGFloat = 0.92
    var wobAmp: CGFloat = 0.8, wobWl: CGFloat = 80, wobTr: CGFloat = 0.16
    var step: CGFloat = 1.8
    var swell: CGFloat = 0.4
    var halo: CGFloat = 0.14, bleed: CGFloat = 1.05
    var core: CGFloat = 0.36, pool: CGFloat = 1
    var skip: CGFloat = 0.3
    var marker = false

    /// felt('ink')
    static let felt = Pen()
    /// felt, 'fine' class: outlines of small controls.
    static let fine = Pen(W: 1.7 * 0.68, alpha: 0.94, wobAmp: 0.56, wobWl: 96, wobTr: 0.1, step: 1.6, swell: 0.18,
                          halo: 0.077, bleed: 0.63, core: 0.29, pool: 0.7, skip: 0.12)
    /// felt, 'brush' class: big underlines.
    static let brush = Pen(W: 3.4, alpha: 0.9, wobAmp: 0.88, wobWl: 88, wobTr: 0.12, step: 2.2, swell: 0.8,
                           halo: 0.12, bleed: 1.26, core: 0.4, pool: 1.15, skip: 0.15)
    /// marker('marker'): the terracotta marker.
    static let marker = Pen(W: 9, alpha: 0.62, wobAmp: 0.9, wobWl: 90, wobTr: 0.1, step: 2.2, swell: 0,
                            halo: 0.22, bleed: 1, core: 0, pool: 0, skip: 0, marker: true)
    /// The highlighter ('hi').
    static let highlighter = Pen(W: 14, alpha: 0.52, wobAmp: 0.5, wobWl: 160, wobTr: 0.05, step: 2.4, swell: 0,
                                 halo: 0.2, bleed: 0.6, core: 0, pool: 0, skip: 0, marker: true)

    func scaled(_ k: CGFloat) -> Pen { var p = self; p.W *= k; p.bleed *= max(0.6, k); return p }
}

/// One drawn stroke: its ink layers (path + opacity) and its centre line,
/// which a "drawing on" animation follows.
struct InkStroke {
    var layers: [(path: CGPath, opacity: CGFloat)] = []
    var centre = CGMutablePath()
    var reach: CGFloat = 4

    static func + (a: InkStroke, b: InkStroke) -> InkStroke {
        let c = CGMutablePath()
        c.addPath(a.centre)
        c.addPath(b.centre)
        return InkStroke(layers: a.layers + b.layers, centre: c, reach: max(a.reach, b.reach))
    }

    /// Fills the stroke into the current context.
    func fill(in ctx: CGContext, color: CGColor) {
        for l in layers {
            ctx.saveGState()
            ctx.setAlpha(l.opacity)
            ctx.setFillColor(color)
            ctx.addPath(l.path)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// As layers, for animating. Sublayers of one container, in layer space.
    func layer(color: CGColor, frame: CGRect) -> CALayer {
        let host = CALayer()
        host.frame = frame
        for l in layers {
            let s = CAShapeLayer()
            s.frame = host.bounds
            s.path = l.path
            s.fillColor = color
            s.opacity = Float(l.opacity)
            host.addSublayer(s)
        }
        return host
    }
}

enum Ink {
    // MARK: Strokes

    /// A felt or marker stroke through `pts` (a polyline; dense or not).
    static func stroke(_ pts: [CGPoint], pen P: Pen, seed: UInt32, press: ((CGFloat) -> CGFloat)? = nil) -> InkStroke {
        guard pts.count > 1 else { return InkStroke() }
        var rng = InkRandom(seed)
        // Resample at an even step.
        let (X0, S0, L) = resample(pts, step: P.step)
        let N = X0.count
        guard N > 2, L > 0.5 else { return InkStroke() }
        var X = X0
        var rn = rng.fork()
        let nLow = InkNoise(&rn, length: L, wavelength: P.wobWl)
        let nMid = InkNoise(&rn, length: L, wavelength: P.wobWl * 0.3)
        let nTr = InkNoise(&rn, length: L, wavelength: 4.5)
        let nW9 = InkNoise(&rn, length: L, wavelength: 9)
        let nP40 = InkNoise(&rn, length: L, wavelength: 40)
        let nDry = InkNoise(&rn, length: L, wavelength: 26)
        let nFlow = InkNoise(&rn, length: L, wavelength: 18)
        let nH = InkNoise(&rn, length: L, wavelength: 7)

        // Wobble sideways.
        let amp = P.wobAmp * min(1.4, max(0.2, L / 120))
        var shifted = X
        for i in 0..<N {
            let a = X[max(0, i - 1)], b = X[min(N - 1, i + 1)]
            let tx = b.x - a.x, ty = b.y - a.y, l = max(hypot(tx, ty), 0.0001)
            let off = amp * (nLow(S0[i]) + 0.3 * nMid(S0[i])) + P.wobTr * nTr(S0[i])
            shifted[i].x += ty / l * off
            shifted[i].y -= tx / l * off
        }
        X = shifted

        // Tangents, normals, turning, pen speed.
        var NX = [CGFloat](repeating: 0, count: N), NY = NX, TX = NX, TY = NX, th = NX, turn = NX, V = NX
        for i in 0..<N {
            let a = X[max(0, i - 1)], b = X[min(N - 1, i + 1)]
            let tx = b.x - a.x, ty = b.y - a.y, l = max(hypot(tx, ty), 0.0001)
            TX[i] = tx / l; TY[i] = ty / l; NX[i] = TY[i]; NY[i] = -TX[i]
            th[i] = atan2(ty, tx)
        }
        for i in 0..<N {
            let a = max(0, i - 2), b = min(N - 1, i + 2)
            var d = th[b] - th[a]
            if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
            turn[i] = d * 4 / CGFloat(max(1, b - a))
        }
        let seg = L / CGFloat(N - 1)
        var er = rng.fork()
        let flick = er.next() < 0.5
        let startPool = er.next() < 0.8
        for i in 0..<N {
            let vA = min(1, sqrt((S0[i] + 0.6) / 9))
            let vD = flick ? 1 : min(1, sqrt((L - S0[i] + 0.6) / 11))
            let vC = 1 / (1 + abs(turn[i]) / (4 * seg) * 5)
            V[i] = min(vA, vD, vC)
        }
        for _ in 0..<2 {
            for i in 1..<N { V[i] = min(V[i], V[i - 1] * 0.55 + V[i] * 0.45 + 0.08) }
            for i in stride(from: N - 2, through: 0, by: -1) { V[i] = min(V[i], V[i + 1] * 0.55 + V[i] * 0.45 + 0.08) }
        }

        // Half widths.
        var hw = [CGFloat](repeating: 0, count: N)
        let taper = min(L * 0.35, 2.5 + 3.5 * P.W)
        for i in 0..<N {
            let toEnd = L - S0[i]
            let pr = press?(S0[i] / L) ?? 1
            var h: CGFloat
            if P.marker {
                let chisel = 0.8 + 0.2 * abs(sin(th[i] + 0.75))
                h = 0.5 * P.W * chisel * pr * (1 + 0.06 * nW9(S0[i]))
                if flick && toEnd < min(0.25 * L, 0.5 * P.W) { h *= 0.6 + 0.4 * toEnd / min(0.25 * L, 0.5 * P.W) }
            } else {
                h = 0.5 * P.W * (0.8 + P.swell * (1 - V[i])) * pr * (1 + 0.1 * nW9(S0[i])) * (1 + 0.07 * nP40(S0[i]))
                h *= 1 + 0.16 * exp(-S0[i] / 2.5)
                if flick && toEnd < taper { h *= 0.3 + 0.7 * pow(max(0, toEnd) / taper, 0.75) }
                if P.skip > 0 && V[i] > 0.9 {
                    let dry = nDry(S0[i]), t = 1 - 0.55 * P.skip
                    if dry > t { h *= max(0.42, 1 - (dry - t) * 5) }
                }
            }
            hw[i] = max(0.12, h)
        }
        // On tight inside turns the ribbon must not fold over itself.
        func clampInner(_ lo: inout [CGFloat], _ ro: inout [CGFloat]) {
            for i in 0..<N {
                let k = abs(turn[i]) / (4 * seg)
                guard k > 0.001 else { continue }
                let lim = 0.85 / k
                if turn[i] > 0 { ro[i] = min(ro[i], lim) } else { lo[i] = min(lo[i], lim) }
            }
        }
        func lane(_ l: (Int) -> CGFloat, _ r: (Int) -> CGFloat, caps: Bool) -> CGPath {
            var lo = (0..<N).map(l), ro = (0..<N).map(r)
            clampInner(&lo, &ro)
            var poly: [CGPoint] = []
            for i in 0..<N { poly.append(CGPoint(x: X[i].x + NX[i] * lo[i], y: X[i].y + NY[i] * lo[i])) }
            let capN = 3
            if caps {
                let b = N - 1, rr = (lo[b] + ro[b]) / 2
                for k in 1...capN {
                    let ph = CGFloat(k) / CGFloat(capN + 1) * .pi, c = cos(ph), s = sin(ph), w = c >= 0 ? lo[b] : ro[b]
                    poly.append(CGPoint(x: X[b].x + NX[b] * w * c + TX[b] * rr * s, y: X[b].y + NY[b] * w * c + TY[b] * rr * s))
                }
            }
            for i in stride(from: N - 1, through: 0, by: -1) { poly.append(CGPoint(x: X[i].x - NX[i] * ro[i], y: X[i].y - NY[i] * ro[i])) }
            if caps {
                let rr = (lo[0] + ro[0]) / 2
                for k in 1...capN {
                    let ph = CGFloat(k) / CGFloat(capN + 1) * .pi, c = cos(ph), s = sin(ph), w = c >= 0 ? ro[0] : lo[0]
                    poly.append(CGPoint(x: X[0].x - NX[0] * w * c - TX[0] * rr * s, y: X[0].y - NY[0] * w * c - TY[0] * rr * s))
                }
            }
            return smoothClosed(poly)
        }

        var out = InkStroke()
        var rl = rng.fork()
        if P.marker {
            out.layers.append((lane({ hw[$0] + P.bleed * (0.5 + 0.5 * nH(S0[$0])) }, { hw[$0] + P.bleed * (0.5 + 0.5 * nH(S0[$0] + 9)) }, caps: false), P.alpha * P.halo))
            out.layers.append((lane({ hw[$0] }, { hw[$0] }, caps: false), P.alpha))
        } else {
            if P.halo > 0 {
                var ja: CGFloat = 0.5
                let A = (0..<N).map { i -> CGFloat in
                    ja = 0.5 * ja + 0.5 * rl.next()
                    return hw[i] + P.bleed * (0.4 + 0.85 * max(0, nH(S0[i])) + 0.4 * ja + 0.4 * (1 - V[i]))
                }
                out.layers.append((lane({ A[$0] }, { A[$0] }, caps: true), P.halo))
            }
            let jit = (0..<N).map { _ in 1 + 0.07 * (rl.next() - 0.5) }
            out.layers.append((lane({ hw[$0] * jit[$0] }, { hw[$0] * jit[N - 1 - $0] }, caps: true), P.alpha))
            let core = (0..<N).map { i -> CGFloat in
                let c = 0.72 * hw[i] * max(pow(1 - V[i], 1.2), 0.8 * (0.5 + 0.5 * nFlow(S0[i])) - 0.1)
                return c > 0.18 ? c : 0
            }
            if core.contains(where: { $0 > 0 }) { out.layers.append((lane({ core[$0] }, { core[$0] }, caps: true), P.core)) }
            // Ink pools where the pen sat.
            let pools = CGMutablePath()
            func pool(_ i: Int, _ k: CGFloat) {
                pools.addPath(blob(X[i], r: hw[i] * k * P.pool, jag: 0.14, rng: &rl))
            }
            if startPool { pool(0, 1.05 + 0.25 * rl.next()) }
            if !flick { pool(N - 1, 0.95 + 0.3 * rl.next()) }
            var last = -9
            for i in 2..<max(2, N - 2) where abs(turn[i]) > 1.35 && i - last > 4 {
                pool(i, 0.6 + 0.25 * min(1, abs(turn[i]) - 1.35)); last = i
            }
            if !pools.isEmpty { out.layers.append((pools, min(1, P.core * 1.1))) }
        }
        let centre = CGMutablePath()
        centre.addLines(between: X)
        out.centre = centre
        out.reach = (hw.max() ?? 1) * 2 + P.bleed * 3 + 2
        return out
    }

    // MARK: Shapes a hand would draw

    /// A straight line drawn by hand: a little bow, never ruler-straight.
    static func line(_ a: CGPoint, _ b: CGPoint, bow: CGFloat = 0.6, seed: UInt32) -> [CGPoint] {
        var r = InkRandom(seed)
        let bend = (r.next() - 0.5) * 2 * bow
        let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 6))
        let dx = b.x - a.x, dy = b.y - a.y, l = max(hypot(dx, dy), 0.001)
        return (0...n).map { k in
            let t = CGFloat(k) / CGFloat(n), s = sin(t * .pi) * bend
            return CGPoint(x: a.x + dx * t - dy / l * s, y: a.y + dy * t + dx / l * s)
        }
    }

    /// A box drawn in one go round a rectangle: starts near a corner, goes
    /// all the way round and overshoots a little past where it began.
    static func box(_ r: CGRect, radius: CGFloat = 3, seed: UInt32, overshoot: CGFloat = 0.06) -> [CGPoint] {
        var rng = InkRandom(seed)
        let rad = min(radius, r.width / 2, r.height / 2)
        var ring: [CGPoint] = []
        // Corners clockwise from top-left (y up), each rounded with 4 points.
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: r.minX + rad, y: r.maxY - rad), .pi), (CGPoint(x: r.maxX - rad, y: r.maxY - rad), .pi / 2),
            (CGPoint(x: r.maxX - rad, y: r.minY + rad), 0), (CGPoint(x: r.minX + rad, y: r.minY + rad), -.pi / 2),
        ]
        for (c, a0) in corners {
            for k in 0...4 {
                let a = a0 - CGFloat(k) / 4 * (.pi / 2)
                ring.append(CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad))
            }
        }
        // Dense ring, then start a little along the top edge and overshoot.
        let (dense, S, L) = resample(ring + [ring[0]], step: 2)
        let start = L * (0.02 + 0.05 * rng.next())
        let end = start + L * (1 + overshoot * (0.6 + 0.8 * rng.next()))
        let drift = (rng.next() - 0.5) * 2.2   // the second pass lands off the first
        var pts: [CGPoint] = []
        var s = start
        while s <= end {
            let u = s.truncatingRemainder(dividingBy: L)
            let i = min(dense.count - 1, S.firstIndex(where: { $0 >= u }) ?? 0)
            var p = dense[i]
            if s > L { p.y += drift * min(1, (s - L) / (L * overshoot + 1)) }
            pts.append(p)
            s += 3
        }
        return pts
    }

    /// A loose loop round something, like circling a date: an ellipse that
    /// does not quite close on itself and comes round a second time.
    static func loop(_ r: CGRect, seed: UInt32, turns: CGFloat = 1.12) -> [CGPoint] {
        var rng = InkRandom(seed)
        let a0 = .pi * (0.55 + 0.3 * rng.next())
        let tilt = (rng.next() - 0.5) * 0.18
        let n = Int(max(24, (r.width + r.height) * 0.9))
        let grow = 0.05 + 0.05 * rng.next()
        return (0...n).map { k in
            let t = CGFloat(k) / CGFloat(n)
            let a = a0 - t * turns * 2 * .pi
            let k1 = 1 + grow * t
            let x = cos(a) * r.width / 2 * k1, y = sin(a) * r.height / 2 * k1
            return CGPoint(x: r.midX + x * cos(tilt) - y * sin(tilt), y: r.midY + x * sin(tilt) + y * cos(tilt))
        }
    }

    // MARK: Animation

    /// Draws `host` (made by `InkStroke.layer`) on, following the stroke.
    static func drawOn(_ host: CALayer, stroke: InkStroke, dur: Double = 0.6, delay: Double = 0) {
        guard Motion.enabled else { return }
        let m = CAShapeLayer()
        m.frame = host.bounds
        m.path = stroke.centre
        m.fillColor = nil
        m.strokeColor = NSColor.black.cgColor
        m.lineWidth = stroke.reach * 2 + 2
        m.lineCap = .round
        m.lineJoin = .round
        host.mask = m
        let a = Motion.anim("strokeEnd", from: 0, to: 1, dur: dur, delay: delay, timing: Motion.inOut)
        a.fillMode = .backwards
        m.add(a, forKey: "draw")
        Motion.after(delay + dur + 0.05) { if host.mask === m { host.mask = nil } }
    }

    // MARK: Geometry

    /// Points every `step` along a polyline, with their distance along it.
    static func resample(_ pts: [CGPoint], step: CGFloat) -> ([CGPoint], [CGFloat], CGFloat) {
        var cum: [CGFloat] = [0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let L = cum.last ?? 0
        guard L > 0 else { return (pts, cum, 0) }
        let n = max(2, Int(ceil(L / step)))
        var out: [CGPoint] = [], S: [CGFloat] = []
        var j = 0
        for k in 0...n {
            let s = L * CGFloat(k) / CGFloat(n)
            while j < cum.count - 2 && cum[j + 1] < s { j += 1 }
            let seg = max(cum[j + 1] - cum[j], 0.0001), t = (s - cum[j]) / seg
            out.append(CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * t, y: pts[j].y + (pts[j + 1].y - pts[j].y) * t))
            S.append(s)
        }
        return (out, S, L)
    }

    /// A closed, smooth outline through `poly` (quadratic curves through midpoints).
    static func smoothClosed(_ poly: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard poly.count > 2 else { return p }
        let n = poly.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        p.move(to: mid(poly[n - 1], poly[0]))
        for i in 0..<n { p.addQuadCurve(to: mid(poly[i], poly[(i + 1) % n]), control: poly[i]) }
        p.closeSubpath()
        return p
    }

    static func blob(_ c: CGPoint, r: CGFloat, jag: CGFloat, rng: inout InkRandom, count: Int = 11) -> CGPath {
        let a0 = rng.next() * 2 * .pi
        let pts = (0..<count).map { i -> CGPoint in
            let a = a0 + CGFloat(i) / CGFloat(count) * 2 * .pi
            let rr = r * (1 + jag * (rng.next() * 2 - 1))
            return CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        }
        return smoothClosed(pts)
    }

    /// A stable seed from a string (so a control draws the same each launch).
    static func seed(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }
}

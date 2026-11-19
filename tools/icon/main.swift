import AppKit

// Draws Galley's app icon: a felt-pen integral sign on ruled Looseleaf paper,
// swiped with highlighter and circled in orange (Sources/Galley/Ink.swift).
// Build: swiftc -O -o /tmp/galleyicon tools/icon/stub.swift Sources/Galley/Ink.swift tools/icon/main.swift
// Run:   /tmp/galleyicon Resources/Paper Resources/icon-1024.png
//
// Geometry is written in 1024 px icon space; everything is drawn in a space
// five times smaller and scaled up, so the pen wobbles and swells exactly as
// it does at interface size.

let K: CGFloat = 5
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x / K, y: y / K) }
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

// Looseleaf colours.
let ink = hex(0x2A2420), card = hex(0xFBF6E9), photo = hex(0xFFFDF6)
let bubblegum = hex(0xF38BB8), tangerine = hex(0xF59A2F), lemon = hex(0xFBD63A)
let grass = hex(0x5DB85C), sky = hex(0x4AA8E8), grape = hex(0x8F6FD6), marker = hex(0xDF6B3C)
let gold = hex(0xF7C34A), shade = hex(0x3A2C1E)

// MARK: Paths

/// A path made of cubic curves, kept as segments so it can be both filled
/// and handed to the pen as a polyline.
struct Shape {
    var start: CGPoint
    var segs: [(CGPoint, CGPoint, CGPoint)] = []
    init(_ s: CGPoint) { start = s }
    mutating func c(_ c1: CGPoint, _ c2: CGPoint, _ to: CGPoint) { segs.append((c1, c2, to)) }
    var cg: CGPath {
        let p = CGMutablePath()
        p.move(to: start)
        for (a, b, t) in segs { p.addCurve(to: t, control1: a, control2: b) }
        p.closeSubpath()
        return p
    }
    func points(closed: Bool = true) -> [CGPoint] {
        var out = [start]
        var cur = start
        for (a, b, t) in segs {
            for k in 1...24 {
                let u = CGFloat(k) / 24, v = 1 - u
                out.append(CGPoint(x: v*v*v*cur.x + 3*v*v*u*a.x + 3*v*u*u*b.x + u*u*u*t.x,
                                   y: v*v*v*cur.y + 3*v*v*u*a.y + 3*v*u*u*b.y + u*u*u*t.y))
            }
            cur = t
        }
        if closed { out.append(start); out.append(out[1]) }   // overshoot a little past the start, like a hand
        return out
    }
}

func cubicPoints(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, n: Int = 40) -> [CGPoint] {
    (0...n).map { k in
        let u = CGFloat(k) / CGFloat(n), v = 1 - u
        return CGPoint(x: v*v*v*p0.x + 3*v*v*u*p1.x + 3*v*u*u*p2.x + u*u*u*p3.x,
                       y: v*v*v*p0.y + 3*v*v*u*p1.y + 3*v*u*u*p2.y + u*u*u*p3.y)
    }
}

// MARK: Canvas

let args = CommandLine.arguments
let paperDir = args[1], out = args[2]
let N = 1024
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

// The macOS icon grid: an 824 px rounded square, centred.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Sheet shadow, warm brown like Looseleaf's.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: hex(0x3A2C1E, 0.35))
ctx.addPath(squircle); ctx.setFillColor(card); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.setFillColor(card); ctx.fill(tile)
// Paper tooth: Looseleaf's tiles, drawn at their real pixel size.
for (name, alpha) in [("relief", 1.0), ("fibre", 1.0), ("cloud", 0.8)] {
    if let img = NSImage(contentsOfFile: "\(paperDir)/\(name)@2x.png")?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let w = CGFloat(img.width) * (name == "cloud" ? 3 : 1), h = CGFloat(img.height) * (name == "cloud" ? 3 : 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h), byTiling: true)
        ctx.restoreGState()
    }
}

// Blue rules and the red margin, like the source sheet.
ctx.setFillColor(hex(0x8FB0D4, 0.75))
var ry: CGFloat = 170
while ry < 924 { ctx.fill(CGRect(x: 100, y: ry, width: 824, height: 3)); ry += 92 }
ctx.setFillColor(hex(0xD9776A, 0.85))
ctx.fill(CGRect(x: 250, y: 100, width: 4, height: 824))
ctx.fill(CGRect(x: 262, y: 100, width: 2, height: 824))

// From here on, draw in the small space.
ctx.scaleBy(x: K, y: K)
let felt = Pen.felt.scaled(1.25)

func outline(_ pts: [CGPoint], seed: UInt32, pen: Pen = felt, color: CGColor = ink) {
    Ink.stroke(pts, pen: pen, seed: seed).fill(in: ctx, color: color)
}
func fill(_ p: CGPath, _ c: CGColor) { ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath() }

// MARK: Highlighter swipe behind the sign

ctx.saveGState()
ctx.setBlendMode(.multiply)
for (i, y) in [CGFloat(505)].enumerated() {
    let s = Ink.stroke(Ink.line(P(300, y), P(780, y - 18), bow: 2, seed: UInt32(80 + i)), pen: Pen.highlighter.scaled(2.3), seed: UInt32(80 + i))
    s.fill(in: ctx, color: lemon)
}
ctx.restoreGState()

// MARK: The integral sign, in a fat felt pen

let sign = cubicPoints(P(690, 800), P(620, 860), P(560, 790), P(548, 640), n: 50)
    + cubicPoints(P(548, 640), P(536, 470), P(526, 330), P(470, 250), n: 60).dropFirst()
    + cubicPoints(P(470, 250), P(430, 200), P(368, 220), P(352, 268), n: 40).dropFirst()
outline(Array(sign), seed: 7, pen: Pen.brush.scaled(3.1))

// MARK: The SyncTeX loop, in orange felt

outline(Ink.loop(CGRect(x: 250 / K, y: 170 / K, width: 560 / K, height: 720 / K), seed: 21), seed: 21, pen: Pen.felt.scaled(3.2), color: marker)

// MARK: Sparkles

func sparkle(_ c: CGPoint, _ r: CGFloat, _ colour: CGColor, seed: UInt32) {
    let p = CGMutablePath()
    let pts = (0..<8).map { i -> CGPoint in
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let rr = i % 2 == 0 ? r : r * 0.32
        return CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
    }
    p.addLines(between: pts); p.closeSubpath()
    fill(p, colour)
    outline(pts + [pts[0], pts[1]], seed: seed, pen: Pen.fine.scaled(1.1))
}
sparkle(P(812, 196), 46 / K, lemon, seed: 71)
sparkle(P(196, 820), 26 / K, sky, seed: 72)

// MARK: Washi tape across the top right corner

ctx.saveGState()
ctx.translateBy(x: 828 / K, y: 828 / K)
ctx.rotate(by: 0.72)
let tape = CGRect(x: -150 / K, y: -30 / K, width: 300 / K, height: 60 / K)
ctx.setFillColor(hex(0xEDE6D2, 0.78)); ctx.fill(tape)
ctx.setFillColor(hex(0x8C8778, 0.55))
ctx.fill(CGRect(x: tape.minX, y: tape.minY, width: tape.width, height: 0.25))
ctx.fill(CGRect(x: tape.minX, y: tape.maxY - 0.25, width: tape.width, height: 0.25))
ctx.restoreGState()

ctx.restoreGState()   // end clip

ctx.addPath(squircle)
ctx.setStrokeColor(hex(0x8E887F, 0.35)); ctx.setLineWidth(2); ctx.strokePath()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)

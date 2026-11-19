import AppKit
import CoreText

/// Looseleaf (kevintngo.github.io/looseleaf, MIT): paper with tooth, felt-pen
/// outlines with pressure, solid fills that sit inside them, washi tape, a
/// highlighter. The one change is the desk: warm stone
/// (#EDE8E0) instead of Looseleaf's sage. Values are Looseleaf's own tokens.
/// Every colour is dynamic; the app stays light unless View › Follow System
/// Dark Mode is on. Layers need `cg(_:in:)`.
enum Theme {
    // MARK: Desk and paper

    /// The desk behind everything: warm stone.
    static let ink = dyn("GalleyDesk", dark: 0x1C1A17, light: 0xEDE8E0)
    /// Same desk where pages sit when the window is opaque.
    static let inkDeep = dyn("GalleyDeskDeep", dark: 0x1C1A17, light: 0xEDE8E0)
    /// Laid over the see-through backdrop when glass is turned on.
    static let tint = dyn("GalleyTint", dark: 0x1C1A17, light: 0xEDE8E0, darkAlpha: 0.62, lightAlpha: 0.66)
    /// Paper stocks (--ll-paper, --ll-slip, --ll-card, --ll-photo, --ll-sticky-yellow).
    static let paperStock = dyn("GalleyPaper", dark: 0x2A2724, light: 0xF8F5EE)
    static let slip = dyn("GalleySlip", dark: 0x2E2B27, light: 0xFBF8F1)
    static let card = dyn("GalleyCard", dark: 0x2C2925, light: 0xFBF6E9)
    static let photo = dyn("GalleyPhoto", dark: 0x302D29, light: 0xFFFDF6)
    static let sticky = dyn("GalleySticky", dark: 0x5C5230, light: 0xF7E38A)
    /// Kept for code that wants plain white-ish paper (signature pad).
    static let paper = hex(0xF8F5EE)
    static let ground2 = paperStock

    // MARK: Inks

    /// --ll-marker: the orange of chosen things and the main button.
    static let accent = dyn("GalleyMarker", dark: 0xE8845C, light: 0xDF6B3C)
    static let accentSoft = dyn("GalleyMarkerSoft", dark: 0xE8845C, light: 0xDF6B3C, darkAlpha: 0.22, lightAlpha: 0.16)
    /// --ll-hi: highlighter yellow, the fill of a chosen tab.
    static let hi = dyn("GalleyHi", dark: 0xC9AE2E, light: 0xF8DC4C)
    /// --ll-ink-you: blue felt pen, for links and the reader's own marks. (Was sage.)
    static let sage = dyn("GalleyInkYou", dark: 0x8FAEEA, light: 0x2C4F9E)
    /// --ll-red.
    static let clay = dyn("GalleyRed", dark: 0xE07360, light: 0xC2412D)
    static let green = dyn("GalleyGreen", dark: 0x7FBF8E, light: 0x3B7A4B)
    /// --ll-ink, --ll-ink-soft, --ll-pencil-text.
    static let text = dyn("GalleyText", dark: 0xECE6D9, light: 0x2A2420)
    static let text2 = dyn("GalleyText2", dark: 0xD9D2C3, light: 0x4A423B)
    static let text3 = dyn("GalleyText3", dark: 0xA3A6AD, light: 0x6B6660)
    /// --ll-pencil-mark: pencil lines and dividers.
    static let rule = dyn("GalleyRule", dark: 0x6A6E78, light: 0x8E887F)
    /// Ruled paper: blue lines and the red margin.
    static let ruleBlue = dyn("GalleyRuleBlue", dark: 0x3E4A5C, light: 0x8FB0D4)
    static let ruleRed = dyn("GalleyRuleRed", dark: 0x8A4A42, light: 0xD9776A)
    /// Washi tape and its edge.
    static let tape = dyn("GalleyTape", dark: 0xD9D4C6, light: 0xF6F4EC, darkAlpha: 0.22, lightAlpha: 0.55)
    static let tapeEdge = dyn("GalleyTapeEdge", dark: 0xD9D4C6, light: 0x8C8778, darkAlpha: 0.25, lightAlpha: 0.35)
    /// --ll-shade: shadows are warm brown, never grey.
    static let shade = NSColor(srgbRed: 58 / 255, green: 44 / 255, blue: 30 / 255, alpha: 1)

    // MARK: Appearance

    /// Off (default): always the light paper. On: follow the Mac's dark mode.
    static var followSystem: Bool {
        get {
            UserDefaults.standard.register(defaults: ["GalleyFollowSystemAppearance": false])
            return UserDefaults.standard.bool(forKey: "GalleyFollowSystemAppearance")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "GalleyFollowSystemAppearance")
            applyAppearance()
        }
    }

    static func applyAppearance() {
        NSApp.appearance = followSystem ? nil : NSAppearance(named: .aqua)
    }

    // MARK: Type

    /// Registers the bundled fonts (Resources/Fonts) for this process only.
    static func registerFonts() {
        guard let dir = resources?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where ["ttf", "otf", "woff2"].contains(f.pathExtension) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    /// The app's Resources folder, also when the bare binary is run from .build.
    static var resources: URL? {
        if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("Fonts").path) { return r }
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<5 {
            u.deleteLastPathComponent()
            let r = u.appendingPathComponent("Resources")
            if FileManager.default.fileExists(atPath: r.appendingPathComponent("Fonts").path) { return r }
        }
        return nil
    }

    /// Kevin Sans, Looseleaf's hand: every label, title and button.
    static func hand(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "KevinSans-Bold" : "KevinSans-Regular", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// IBM Plex Mono for figures: page numbers, zoom, counts.
    static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "IBMPlexMono-Regular", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Old names, so earlier callers draw in the hand too.
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        hand(size, bold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        hand(size, bold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont { mono(size - 1) }

    // MARK: Paper texture

    /// Looseleaf's paper tiles (fibre, relief, cloud), drawn over the stock
    /// colour to give the paper its tooth. Made once, repeated as patterns.
    static let paperTiles: [NSColor] = {
        ["fibre": 240.0, "relief": 192.0, "cloud": 720.0].sorted { $0.value < $1.value }.compactMap { name, pts in
            guard let url = resources?.appendingPathComponent("Paper/\(name)@2x.png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            img.size = NSSize(width: pts, height: pts)
            return NSColor(patternImage: img)
        }
    }()

    static let slipTile: NSColor? = {
        guard let url = resources?.appendingPathComponent("Paper/slip@2x.png"), let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 128, height: 128)
        return NSColor(patternImage: img)
    }()

    /// Fills `rect` with paper: the stock colour, then its tooth.
    static func fillPaper(_ rect: NSRect, stock: NSColor, slip: Bool = false) {
        stock.setFill()
        rect.fill()
        let tiles = slip ? [slipTile].compactMap { $0 } + paperTiles.suffix(1) : paperTiles
        // The tiles are made for light paper; on night paper their white
        // fibres read as scratches, so they go in at a third of the strength.
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        if isDark(NSAppearance.currentDrawing()) { ctx?.setAlpha(0.3) }
        for t in tiles {
            t.setFill()
            rect.fill(using: .sourceOver)
        }
        ctx?.restoreGState()
    }

    // MARK: Helpers

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static func isDark(_ a: NSAppearance) -> Bool {
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func dyn(_ name: String, dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: name) { a in isDark(a) ? hex(dark, darkAlpha) : hex(light, lightAlpha) }
    }

    /// A dynamic colour resolved for layers, under `view`'s appearance.
    static func cg(_ c: NSColor, in view: NSView?) -> CGColor {
        var out = c.cgColor
        (view?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }

    /// Looseleaf's card shadow: a tight contact shadow plus a soft drop, warm brown.
    static func cardShadow(_ l: CALayer?, lift: Bool = false) {
        guard let l else { return }
        l.shadowColor = shade.cgColor
        l.shadowOpacity = lift ? 0.3 : 0.24
        l.shadowRadius = lift ? 9 : 6
        l.shadowOffset = CGSize(width: 0, height: lift ? -7 : -4)
    }
}

/// The desk: flat stone. Over the glass backdrop (when turned on) it is
/// drawn see-through.
final class WarmTint: NSView {
    var color: NSColor = Theme.tint { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

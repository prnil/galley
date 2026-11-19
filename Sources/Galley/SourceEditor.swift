import AppKit

/// The source sheet: ruled Looseleaf paper with a red margin, line numbers
/// in the gutter, TeX coloured in felt-pen inks, section titles swiped with
/// a highlighter, and red felt marks beside lines TeX complained about.

extension NSAttributedString.Key {
    /// Ranges a highlighter swipe is drawn under (section titles).
    static let galleyMarker = NSAttributedString.Key("GalleyMarker")
}

enum EditorMetrics {
    static let lineHeight: CGFloat = 22
    static let gutter: CGFloat = 46
    static let top: CGFloat = 26
    static var fontSize: CGFloat {
        get { UserDefaults.standard.register(defaults: ["GalleyFontSize": 13.5]); return CGFloat(UserDefaults.standard.double(forKey: "GalleyFontSize")) }
        set { UserDefaults.standard.set(Double(min(24, max(10, newValue))), forKey: "GalleyFontSize") }
    }
}

// MARK: Colouring

final class TeXHighlighter: NSObject, NSTextStorageDelegate {
    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private let command = re("\\\\(?:[A-Za-z@]+\\*?|.)")
    private let env = re("\\\\(begin|end)\\{([^}\\n]*)\\}")
    private let inlineMath = re("(?<!\\\\)\\$(?:\\\\.|[^$\\\\\\n])+\\$|\\\\\\((?:.|\\n)*?\\\\\\)")
    private let displayMath = re("(?<!\\\\)\\$\\$[\\s\\S]*?\\$\\$|\\\\\\[[\\s\\S]*?\\\\\\]|\\\\begin\\{(equation|align|gather|multline|eqnarray|displaymath|math|flalign|alignat)(\\*?)\\}[\\s\\S]*?\\\\end\\{\\1\\2\\}")
    private let comment = re("(?<!\\\\)%.*$", .anchorsMatchLines)
    private let section = re("\\\\(part|chapter|section|subsection|subsubsection|paragraph|title)\\*?(?:\\[[^\\]\\n]*\\])?\\{([^}\\n]*)\\}")
    private let brace = re("[{}\\[\\]]")
    private let bibEntry = re("^\\s*@[A-Za-z]+\\{([^,\\n]*)", .anchorsMatchLines)

    var isBib = false

    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
        guard mask.contains(.editedCharacters) else { return }
        let ns = ts.string as NSString
        // Small files: colour everything (display maths spans lines). Big ones: the paragraphs round the edit.
        let r: NSRange
        if ns.length < 80_000 {
            r = NSRange(location: 0, length: ns.length)
        } else {
            let lo = max(0, range.location - 3000), hi = min(ns.length, NSMaxRange(range) + 3000)
            r = ns.paragraphRange(for: NSRange(location: lo, length: hi - lo))
        }
        colour(ts, in: r)
    }

    static var mono: NSFont { Theme.mono(EditorMetrics.fontSize) }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = EditorMetrics.lineHeight
        p.maximumLineHeight = EditorMetrics.lineHeight
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let f = mono
        return [.font: f, .foregroundColor: Theme.text, .paragraphStyle: paragraph,
                .baselineOffset: (EditorMetrics.lineHeight - f.ascender + f.descender) / 2 - 2]
    }

    func colour(_ ts: NSTextStorage, in r: NSRange) {
        let s = ts.string
        ts.beginEditing()
        ts.setAttributes(TeXHighlighter.baseAttributes(), range: r)
        func paint(_ re: NSRegularExpression, group: Int = 0, _ attrs: [NSAttributedString.Key: Any]) {
            for m in re.matches(in: s, range: r) where m.range(at: group).location != NSNotFound {
                ts.addAttributes(attrs, range: m.range(at: group))
            }
        }
        if isBib {
            paint(command, [.foregroundColor: Theme.sage])
            paint(bibEntry, group: 0, [.foregroundColor: Theme.clay])
            paint(bibEntry, group: 1, [.foregroundColor: Theme.accent])
            paint(comment, [.foregroundColor: Theme.text3])
            ts.endEditing()
            return
        }
        paint(brace, [.foregroundColor: Theme.rule])
        paint(command, [.foregroundColor: Theme.sage])
        paint(env, group: 2, [.foregroundColor: Theme.clay])
        paint(inlineMath, [.foregroundColor: Theme.accent])
        paint(displayMath, [.foregroundColor: Theme.accent])
        paint(section, group: 2, [.font: Theme.hand(EditorMetrics.fontSize + 2.5, bold: true), .foregroundColor: Theme.text, .galleyMarker: true])
        paint(comment, [.foregroundColor: Theme.text3, .galleyMarker: NSNull()])
        // A comment may have covered part of a heading: a marker of NSNull is no marker.
        ts.enumerateAttribute(.galleyMarker, in: r) { v, rr, _ in if v is NSNull { ts.removeAttribute(.galleyMarker, range: rr) } }
        ts.endEditing()
    }
}

// MARK: The highlighter swipe under headings

final class MarkerLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, let tc = textContainers.first, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let hi = Theme.hi.cgColor
        ts.enumerateAttribute(.galleyMarker, in: chars) { v, r, _ in
            guard v != nil else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                let b = rect.offsetBy(dx: origin.x, dy: origin.y)
                guard b.width > 4 else { return }
                let y = b.maxY - b.height * 0.36
                let seed = Ink.seed(ts.attributedSubstring(from: r).string)
                let pts = Ink.line(CGPoint(x: b.minX - 3, y: y), CGPoint(x: b.maxX + 3, y: y - 0.8), bow: 1.4, seed: seed)
                let stroke = Ink.stroke(pts, pen: Pen.highlighter.scaled(0.78), seed: seed)
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                stroke.fill(in: ctx, color: hi)
                ctx.restoreGState()
            }
        }
    }
}

// MARK: The text view

final class SourceTextView: NSTextView {
    /// 1-based line numbers TeX reported, with their kind.
    var errorLines: Set<Int> = [] { didSet { if errorLines != oldValue { needsDisplay = true } } }
    var warningLines: Set<Int> = [] { didSet { if warningLines != oldValue { needsDisplay = true } } }
    /// ⌘-click: show this line in the PDF.
    var onSync: ((Int) -> Void)?
    var showsNumbers = true

    static func make() -> (NSScrollView, SourceTextView) {
        let storage = NSTextStorage()
        let lm = MarkerLayoutManager()
        lm.allowsNonContiguousLayout = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let tv = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: tc)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = true
        tv.font = TeXHighlighter.mono
        tv.typingAttributes = TeXHighlighter.baseAttributes()
        tv.defaultParagraphStyle = TeXHighlighter.paragraph
        tv.insertionPointColor = Theme.accent
        tv.selectedTextAttributes = [.backgroundColor: Theme.hi.withAlphaComponent(0.45)]
        tv.textContainerInset = NSSize(width: (EditorMetrics.gutter + 16 + 22) / 2, height: EditorMetrics.top)

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.contentView.drawsBackground = false
        return (sv, tv)
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: EditorMetrics.gutter + 16, y: EditorMetrics.top) }

    // MARK: Paper

    override func drawBackground(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        // Paper tooth moves with the text, not with the window.
        ctx.patternPhase = convert(NSPoint.zero, to: nil)
        Theme.fillPaper(rect, stock: Theme.paperStock)
        ctx.restoreGraphicsState()

        let lh = EditorMetrics.lineHeight
        let top = EditorMetrics.top
        // Current line: a faint wash of highlighter.
        if let r = currentLineRect() {
            Theme.hi.withAlphaComponent(0.16).setFill()
            NSRect(x: EditorMetrics.gutter + 1, y: r.minY, width: bounds.width, height: r.height).fill()
        }
        // Blue rules on every line, from the first line down.
        Theme.ruleBlue.withAlphaComponent(0.55).setFill()
        var y = top + lh * floor(max(0, rect.minY - top) / lh) + lh - 1
        while y < rect.maxY + lh {
            if y >= top + lh - 1 { NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill() }
            y += lh
        }
        // The red margin.
        Theme.ruleRed.withAlphaComponent(0.8).setFill()
        NSRect(x: EditorMetrics.gutter, y: rect.minY, width: 1, height: rect.height).fill()
        NSRect(x: EditorMetrics.gutter + 3, y: rect.minY, width: 0.6, height: rect.height).fill()
        drawGutter(in: rect)
    }

    private func currentLineRect() -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, selectedRange().length == 0, window?.firstResponder === self else { return nil }
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        let g = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: g.length == 0 ? NSRange(location: max(0, g.location - 1), length: 0) : g, in: tc)
        if ns.length == 0 || (loc == ns.length && ns.hasSuffix("\n")) { r = lm.extraLineFragmentRect }
        if r.height < 1 { r.size.height = EditorMetrics.lineHeight }
        return r.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }

    private func drawGutter(in rect: NSRect) {
        guard showsNumbers, let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let font = Theme.mono(10.5)
        let origin = textContainerOrigin
        let visible = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let firstChar = lm.characterIndexForGlyph(at: visible.location)
        var line = lineNumber(at: firstChar)
        var idx = visible.location
        let end = NSMaxRange(visible)
        while idx < end {
            var effective = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &effective)
            let c = lm.characterIndexForGlyph(at: idx)
            let startsLine = c == 0 || ns.character(at: c - 1) == 10
            if startsLine {
                drawNumber(line, fragY: frag.minY + origin.y, font: font)
                line += 1
            }
            idx = NSMaxRange(effective)
            if effective.length == 0 { break }
        }
        // The empty last line after a final newline.
        let extra = lm.extraLineFragmentRect
        if extra.height > 0, extra.minY + origin.y < rect.maxY {
            drawNumber(ns.components(separatedBy: "\n").count, fragY: extra.minY + origin.y, font: font)
        }
    }

    private func drawNumber(_ n: Int, fragY: CGFloat, font: NSFont) {
        let lh = EditorMetrics.lineHeight
        let isErr = errorLines.contains(n), isWarn = warningLines.contains(n)
        if isErr || isWarn, let ctx = NSGraphicsContext.current?.cgContext {
            let c = isErr ? Theme.clay : Theme.accent
            // A wash over the line and a felt squiggle down the margin.
            c.withAlphaComponent(isErr ? 0.09 : 0.06).setFill()
            NSRect(x: EditorMetrics.gutter + 4, y: fragY, width: bounds.width, height: lh - 1).fill()
            let x = EditorMetrics.gutter - 4
            let seed = UInt32(n) &* 2_654_435_761
            let pts = Ink.line(CGPoint(x: x, y: fragY + 3), CGPoint(x: x + 0.5, y: fragY + lh - 4), bow: 1.6, seed: seed)
            Ink.stroke(pts, pen: Pen.felt.scaled(1.3), seed: seed).fill(in: ctx, color: c.cgColor)
        }
        let s = "\(n)" as NSString
        let col: NSColor = isErr ? Theme.clay : (isWarn ? Theme.accent : Theme.text3.withAlphaComponent(0.75))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: col]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: EditorMetrics.gutter - 10 - sz.width, y: fragY + (lh - sz.height) / 2), withAttributes: attrs)
    }

    func lineNumber(at charIndex: Int) -> Int {
        let ns = string as NSString
        var n = 1, i = 0
        let end = min(charIndex, ns.length)
        // Count newlines quickly with a character scan.
        while i < end {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: i, length: end - i))
            if r.location == NSNotFound { break }
            n += 1
            i = r.location + 1
        }
        return n
    }

    func rangeOfLine(_ line: Int) -> NSRange? {
        let ns = string as NSString
        var n = 1, i = 0
        while n < line {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { return nil }
            i = r.location + 1
            n += 1
        }
        return ns.lineRange(for: NSRange(location: min(i, ns.length), length: 0))
    }

    var currentLine: Int { lineNumber(at: selectedRange().location) }
    var currentColumn: Int {
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        return loc - ns.lineRange(for: NSRange(location: loc, length: 0)).location
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let before = currentLineRect()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let after = currentLineRect()
        if before != after {
            for r in [before, after].compactMap({ $0 }) { setNeedsDisplay(NSRect(x: 0, y: r.minY - 1, width: bounds.width, height: r.height + 2)) }
        }
    }

    // MARK: Jumping to a line

    /// Selects the line, scrolls it to the middle and swipes it with the highlighter.
    func reveal(line: Int) {
        guard let r = rangeOfLine(line), let lm = layoutManager, let tc = textContainer else { return }
        window?.makeFirstResponder(self)
        var sel = r
        if sel.length > 0, (string as NSString).character(at: NSMaxRange(sel) - 1) == 10 { sel.length -= 1 }
        setSelectedRange(NSRange(location: sel.location, length: 0))
        let g = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: g, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        if let clip = enclosingScrollView?.contentView {
            let y = max(0, min(rect.midY - clip.bounds.height / 2, bounds.height - clip.bounds.height))
            NSAnimationContext.runAnimationGroup { c in
                c.duration = Motion.enabled ? 0.32 : 0
                c.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            } completionHandler: { [weak self] in
                self?.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        swipe(rect.insetBy(dx: -4, dy: 0))
    }

    /// A highlighter stroke drawn across `rect`, which then fades.
    func swipe(_ rect: NSRect) {
        guard let host = layer, rect.width > 2 else { return }
        let w = max(rect.width, 60)
        let frame = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        let seed = UInt32.random(in: 1...1_000_000)
        let y = frame.height * 0.55
        let stroke = Ink.stroke(Ink.line(CGPoint(x: 0, y: y), CGPoint(x: w, y: y + 1), bow: 1.5, seed: seed), pen: Pen.highlighter, seed: seed)
        let l = stroke.layer(color: Theme.cg(Theme.hi, in: self), frame: frame)
        l.compositingFilter = "multiplyBlendMode"
        l.zPosition = 5
        host.addSublayer(l)
        Ink.drawOn(l, stroke: stroke, dur: 0.45)
        let fade = Motion.anim("opacity", from: 1, to: 0, dur: 0.7, delay: 1.5)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        l.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.enabled ? 2.3 * Motion.slow : 1.2)) { l.removeFromSuperlayer() }
    }

    // MARK: Typing

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            let i = characterIndexForInsertion(at: p)
            setSelectedRange(NSRange(location: i, length: 0))
            onSync?(lineNumber(at: i))
            return
        }
        super.mouseDown(with: event)
    }

    override func insertTab(_ sender: Any?) { insertText("  ", replacementRange: selectedRange()) }

    /// Return keeps the indent of the line above.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: loc, length: 0)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    /// ⌘/ comments or uncomments the chosen lines.
    @objc func toggleComment(_ sender: Any?) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let block = ns.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let trailing = parts.last == "" ? parts.removeLast() : nil
        let all = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
        parts = parts.map { l in
            guard !l.trimmingCharacters(in: .whitespaces).isEmpty else { return l }
            if all, let r = l.range(of: "% ") ?? l.range(of: "%") { var m = l; m.removeSubrange(r); return m }
            return all ? l : "% " + l
        }
        var out = parts.joined(separator: "\n")
        if trailing != nil { out += "\n" }
        if shouldChangeText(in: lines, replacementString: out) {
            replaceCharacters(in: lines, with: out)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: (out as NSString).length - (trailing != nil ? 1 : 0)))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        insertionPointColor = Theme.accent
        needsDisplay = true
    }
}

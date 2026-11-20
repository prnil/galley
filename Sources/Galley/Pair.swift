import AppKit
import PDFKit

// Pair mode: the author and Claude go through the document together,
// paragraph by paragraph and page by page. The typeset pages sit on the
// left with the paragraph under review highlighted; the conversation sits
// on the right. Claude's corrections go straight into the source, the
// pages are set again, and the changed lines turn green.
//
// Nothing reaches the author's files until they save (⌘S). Chapters pulled
// in with \input or \include are edited in memory and written back on save,
// each file copied to a dated backup folder first.

// MARK: The document as one flat text

/// Where a line of the flattened text came from: a file and a 1-based line.
struct SourceLine: Hashable { let file: String; let line: Int }

/// One paragraph of prose: lines `start...end` (1-based) of `file`.
struct PairParagraph: Equatable {
    var file: String
    var start: Int
    var end: Int
}

final class PairModel {
    /// Stands for the text in the editor (the main file, possibly unsaved).
    let mainKey: String
    let folder: URL?
    /// Edited chapter files, by absolute path, not yet written to disk.
    private(set) var overlay: [String: String] = [:]
    /// Chapter text as it was on disk when Pair mode first read it.
    private var disk: [String: String] = [:]

    init(mainKey: String, folder: URL?) {
        self.mainKey = mainKey
        self.folder = folder
    }

    var hasUnsavedChapters: Bool { !overlay.isEmpty }

    func text(of file: String, main: String) -> String? {
        if file == mainKey { return main }
        if let t = overlay[file] { return t }
        if let t = disk[file] { return t }
        guard let t = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        disk[file] = t
        return t
    }

    func setChapter(_ file: String, text: String) {
        if disk[file] == text { overlay[file] = nil } else { overlay[file] = text }
    }

    // MARK: Flattening

    private static let inputRE = try! NSRegularExpression(pattern: "\\\\(input|include)\\s*\\{([^}]+)\\}")

    /// The main text with every \input and \include file written in place,
    /// and for each line of the result where it came from (nil for lines
    /// Galley added).
    func flatten(main: String) -> (text: String, map: [SourceLine?]) {
        var out: [String] = []
        var map: [SourceLine?] = []
        add(file: mainKey, text: main, depth: 0, out: &out, map: &map)
        return (out.joined(separator: "\n"), map)
    }

    private func resolve(_ name: String) -> String? {
        guard let folder else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("#") else { return nil }
        let base = n.hasPrefix("/") ? URL(fileURLWithPath: n) : folder.appendingPathComponent(n)
        for u in [base, base.appendingPathExtension("tex")] where u.pathExtension == "tex" || u.pathExtension == "ltx" {
            if FileManager.default.fileExists(atPath: u.path) { return u.standardized.path }
        }
        return nil
    }

    private func add(file: String, text: String, depth: Int, out: inout [String], map: inout [SourceLine?]) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let code = PairModel.stripComment(line) as NSString
            if depth < 6, let m = PairModel.inputRE.firstMatch(in: code as String, range: NSRange(location: 0, length: code.length)),
               let path = resolve(code.substring(with: m.range(at: 2))), path != file,
               let inner = self.text(of: path, main: "") {
                let before = code.substring(to: m.range.location)
                let after = code.substring(from: NSMaxRange(m.range))
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { out.append(before); map.append(SourceLine(file: file, line: i + 1)) }
                let isInclude = code.substring(with: m.range(at: 1)) == "include"
                if isInclude { out.append("\\clearpage"); map.append(nil) }
                add(file: path, text: inner, depth: depth + 1, out: &out, map: &map)
                if isInclude { out.append("\\clearpage"); map.append(nil) }
                if !after.trimmingCharacters(in: .whitespaces).isEmpty { out.append(after); map.append(SourceLine(file: file, line: i + 1)) }
                continue
            }
            out.append(line)
            map.append(SourceLine(file: file, line: i + 1))
        }
    }

    /// The line without its comment (an unescaped % and what follows).
    static func stripComment(_ line: String) -> String {
        var prev: Character = " "
        var result = ""
        for c in line {
            if c == "%" && prev != "\\" { break }
            result.append(c)
            prev = c
        }
        return result
    }

    // MARK: Finding paragraphs

    /// Environments that are not prose: their lines are never sent to Claude.
    static let skipEnvironments: Set<String> = [
        "figure", "figure*", "table", "table*", "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "eqnarray", "eqnarray*", "displaymath", "math", "tikzpicture", "lstlisting",
        "verbatim", "Verbatim", "minted", "tabular", "tabular*", "tabularx", "longtable", "algorithm", "algorithmic",
        "algorithm2e", "thebibliography", "titlepage", "subfigure", "wrapfigure", "pgfpicture", "comment", "filecontents",
    ]
    private static let beginRE = try! NSRegularExpression(pattern: "\\\\begin\\s*\\{([^}]+)\\}")
    private static let endRE = try! NSRegularExpression(pattern: "\\\\end\\s*\\{([^}]+)\\}")
    /// A line that is a heading or page furniture: it ends a paragraph and is never sent.
    private static let breakRE = try! NSRegularExpression(pattern:
        "^\\s*\\\\(part|chapter|section|subsection|subsubsection|paragraph|subparagraph|label|maketitle|tableofcontents|listoffigures|listoftables|clearpage|newpage|cleardoublepage|pagebreak|appendix|frontmatter|mainmatter|backmatter|bibliography|bibliographystyle|printbibliography|vspace|vfill|centering|includegraphics|caption|addcontentsline|thispagestyle|pagestyle|pagenumbering|setcounter|noindent\\s*$)\\b")

    /// The prose paragraphs of the flattened document, in reading order.
    func paragraphs(flat: [String], map: [SourceLine?]) -> [PairParagraph] {
        var result: [PairParagraph] = []
        var inDoc = !flat.contains { PairModel.stripComment($0).contains("\\begin{document}") }
        var skipDepth = 0
        var run: [SourceLine] = []
        var runText: [String] = []

        func flush() {
            // Comment-only lines at either end are not part of the prose.
            while let l = runText.last, PairModel.stripComment(l).trimmingCharacters(in: .whitespaces).isEmpty { runText.removeLast(); run.removeLast() }
            while let l = runText.first, PairModel.stripComment(l).trimmingCharacters(in: .whitespaces).isEmpty { runText.removeFirst(); run.removeFirst() }
            if let a = run.first, let b = run.last, PairModel.wordCount(runText.joined(separator: " ")) >= 6 {
                result.append(PairParagraph(file: a.file, start: a.line, end: b.line))
            }
            run = []; runText = []
        }

        for (i, line) in flat.enumerated() {
            let code = PairModel.stripComment(line)
            let ns = code as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if !inDoc {
                if code.contains("\\begin{document}") { inDoc = true }
                continue
            }
            if code.contains("\\end{document}") { flush(); break }
            let begins = PairModel.beginRE.matches(in: code, range: whole).map { ns.substring(with: $0.range(at: 1)) }.filter { PairModel.skipEnvironments.contains($0) }.count
            let ends = PairModel.endRE.matches(in: code, range: whole).map { ns.substring(with: $0.range(at: 1)) }.filter { PairModel.skipEnvironments.contains($0) }.count
            if begins > 0 || ends > 0 || skipDepth > 0 {
                flush()
                skipDepth = max(0, skipDepth + begins - ends)
                continue
            }
            guard let src = map[i] else { flush(); continue }
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if !trimmed.isEmpty, PairModel.breakRE.firstMatch(in: code, range: whole) != nil { flush(); continue }
            if let last = run.last, last.file != src.file || last.line + 1 != src.line { flush() }
            run.append(src)
            runText.append(line)
        }
        flush()
        return result
    }

    private static let dropRE = try! NSRegularExpression(pattern: "\\\\(cite\\w*|ref|eqref|autoref|cref|Cref|label|url|href|includegraphics)\\*?(\\[[^\\]]*\\])*\\{[^}]*\\}|\\$[^$]*\\$|\\\\[A-Za-z@]+\\*?")

    /// Words of prose, LaTeX commands, citations and maths left out.
    static func wordCount(_ s: String) -> Int {
        let ns = s as NSString
        let plain = dropRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return plain.split { !$0.isLetter && $0 != "'" && $0 != "-" }.filter { $0.count >= 2 }.count
    }

    // MARK: Lines

    /// The range of lines `start...end` (1-based) in `text`, without the final newline.
    static func lineRange(in text: String, start: Int, end: Int) -> NSRange? {
        let ns = text as NSString
        var line = 1, loc = 0
        var from: Int?
        if start == 1 { from = 0 }
        while loc < ns.length {
            let c = ns.character(at: loc)
            if c == 10 {
                if line == end, let f = from { return NSRange(location: f, length: loc - f) }
                line += 1
                if line == start { from = loc + 1 }
            }
            loc += 1
        }
        if let f = from, line == end { return NSRange(location: f, length: ns.length - f) }
        return nil
    }

    /// Writes edited chapters to disk, each first copied into `backup`.
    func writeChapters(backup: URL) -> [String] {
        var written: [String] = []
        for (path, text) in overlay {
            let src = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let dest = backup.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: src, to: dest) }
            do {
                try text.write(to: src, atomically: true, encoding: .utf8)
                disk[path] = text
                written.append(src.lastPathComponent)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        for p in written.map({ n in overlay.keys.first { URL(fileURLWithPath: $0).lastPathComponent == n } }) { if let p { overlay[p] = nil } }
        return written
    }
}

// MARK: Claude

/// Talks to the `claude` command (Claude Code) in streaming JSON, so Pair
/// mode uses the person's own Claude login. One process holds the whole
/// conversation; it has no tools and sees only what Galley sends it.
final class ClaudeSession {
    var onText: ((String) -> Void)?
    var onTurnEnd: ((_ error: String?) -> Void)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var errText = ""
    private var stopping = false

    static var executable: String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude", home + "/.claude/local/claude", home + "/.npm-global/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(cwd: URL?, systemPrompt: String, model: String?) throws {
        guard let exe = ClaudeSession.executable else {
            throw NSError(domain: "Galley", code: 1, userInfo: [NSLocalizedDescriptionKey: "The claude command was not found. Install Claude Code, then try again."])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--tools", "", "--setting-sources", "",
                    "--no-session-persistence", "--system-prompt", systemPrompt]
        if let model, !model.isEmpty { args += ["--model", model] }
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.take(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.errText = String(((self?.errText ?? "") + s).suffix(2000)) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                let why = self.errText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onExit?(why.isEmpty ? "Claude stopped (exit \(proc.terminationStatus))." : why)
            }
        }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func send(_ text: String) {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard let d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        input?.write(d + Data([10]))
    }

    func stop() {
        stopping = true
        try? input?.close()
        process?.terminate()
        process = nil
    }

    private func take(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "stream_event":
            guard let ev = o["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String else { return }
            onText?(t)
        case "result":
            let isError = (o["is_error"] as? Bool) ?? false
            onTurnEnd?(isError ? ((o["result"] as? String) ?? "Claude could not answer.") : nil)
        default: break
        }
    }

    static let instructions = """
    You are Claude in Pair mode inside Galley, a LaTeX editor. The author and you go through their document together, paragraph by paragraph, while the typeset PDF updates live beside the chat. There are no tools; everything you need is in the messages.

    Each turn either hands you the next paragraph (its LaTeX source, with its place in the document) or carries the author's reply about the current paragraph.

    How to answer:
    1. One to three short, plain sentences: what you changed and why, or that the paragraph reads well. Talk like a careful co-author, not a report. No headings, no lists.
    2. If anything should change, the whole revised paragraph, LaTeX source only, between <revised> and </revised>. Nothing else inside the tags, no code fences. Keep its line breaks where they make sense and never add a blank line inside it.
    3. If nothing should change, end with <ok/>.

    What to fix: spelling, grammar, punctuation, awkward or unclear sentences, repetition, inconsistent terms or numbers you can see. Keep the author's meaning, voice and length. Never touch citations (\\cite), labels, references, maths, macros or commands, except to fix an obvious typo in plain words. Never add references or new claims.

    The author's standing rules for their writing:
    - Never use em dashes. Use commas, colons or full stops instead.
    - No first person (I, me, my, we, us, our) except on Declaration or Acknowledgement pages; use passive voice or "this report".
    - Keep chapter and section titles exactly as they are.
    - Plain, natural sentences; bold only for headings.

    When the author asks for something about the current paragraph ("shorter", "keep the first sentence", "undo that"), do it and send the full paragraph again in <revised> tags. If they ask a question, answer it briefly and add <ok/> unless you changed something. Earlier paragraphs are already settled; do not revisit them unless asked.
    """
}

// MARK: Word diff

enum WordDiff {
    enum Part { case same(String), gone(String), new(String) }

    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var space: Bool?
        for c in s {
            let isSpace = c.isWhitespace
            if let sp = space, sp != isSpace { out.append(cur); cur = "" }
            cur.append(c)
            space = isSpace
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func diff(_ a: String, _ b: String) -> [Part] {
        let x = tokens(a), y = tokens(b)
        let n = x.count, m = y.count
        guard n * m < 4_000_000 else { return [.gone(a), .new(b)] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var parts: [Part] = []
        func push(_ p: Part) {
            switch (parts.last, p) {
            case (.same(let s)?, .same(let t)): parts[parts.count - 1] = .same(s + t)
            case (.gone(let s)?, .gone(let t)): parts[parts.count - 1] = .gone(s + t)
            case (.new(let s)?, .new(let t)): parts[parts.count - 1] = .new(s + t)
            default: parts.append(p)
            }
        }
        var i = 0, j = 0
        while i < n && j < m {
            if x[i] == y[j] { push(.same(x[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { push(.gone(x[i])); i += 1 }
            else { push(.new(y[j])); j += 1 }
        }
        while i < n { push(.gone(x[i])); i += 1 }
        while j < m { push(.new(y[j])); j += 1 }
        return grouped(parts)
    }

    /// Reads better as "struck old words, then new words" per change, so a
    /// lone space kept between two edits is folded into the change around it.
    static func grouped(_ parts: [Part]) -> [Part] {
        var out: [Part] = []
        var gone = "", new = ""
        func flush() {
            if !gone.isEmpty { out.append(.gone(gone)) }
            if !new.isEmpty { out.append(.new(new)) }
            gone = ""; new = ""
        }
        for (k, p) in parts.enumerated() {
            switch p {
            case .gone(let s): gone += s
            case .new(let s): new += s
            case .same(let s):
                let inChange = !(gone.isEmpty && new.isEmpty)
                let nextIsChange: Bool = { if k + 1 < parts.count, case .same = parts[k + 1] { return false }; return k + 1 < parts.count }()
                if inChange && nextIsChange && s.allSatisfy(\.isWhitespace) && s.count <= 2 {
                    gone += s; new += s
                } else {
                    flush()
                    out.append(.same(s))
                }
            }
        }
        flush()
        return out
    }
}

// MARK: Marks on the pages

/// A highlighter stroke over a line of the typeset page.
final class MarkAnnotation: PDFAnnotation {
    var tint: NSColor = Theme.hi

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.multiply)
        var c = tint.cgColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { c = tint.cgColor }
        context.setFillColor(c)
        let r = bounds
        let path = CGPath(roundedRect: r, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

// MARK: The conversation sheet

final class PairPane: NSView {
    let sheet = PaperView(stock: Theme.paperStock)
    private let title = handLabel("Pair with Claude", size: 17, bold: true)
    let place = NSTextField(labelWithString: "")
    let modelButton = InkButton(title: "model", target: nil, action: nil)
    let scroll = NSScrollView()
    let transcript = NSTextView()
    let back = InkButton(title: "Back", target: nil, action: nil)
    let undo = InkButton(title: "Undo change", target: nil, action: nil)
    let next = InkButton(title: "Next paragraph", target: nil, action: nil)
    let nextPage = InkButton(title: "Next page", target: nil, action: nil)
    let field = ReplyBox()
    let status = StatusMark()
    var onSend: ((String) -> Void)?

    /// Where Claude's reply now being written sits in the transcript.
    private var liveRange: NSRange?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        sheet.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sheet)

        place.font = Theme.mono(11)
        place.textColor = Theme.text3
        place.lineBreakMode = .byTruncatingMiddle
        modelButton.isBordered = false
        modelButton.font = Theme.mono(11)
        modelButton.toolTip = "Which Claude model reads with you. Changing it starts a fresh conversation."

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 18, height: 14)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript

        for b in [back, undo, next, nextPage, modelButton] { b.isBordered = false }
        next.font = Theme.hand(14, bold: true)
        back.toolTip = "The paragraph before (⌘↑)"
        next.toolTip = "Settle this paragraph and go on (⌘↓, or Return in an empty reply)"
        nextPage.toolTip = "Skip to the first paragraph of the next page"
        undo.toolTip = "Put back the paragraph as it was before Claude's last change"

        field.onSubmit = { [weak self] in self?.submit() }

        let header = NSStackView(views: [title, NSView(), status, modelButton])
        header.spacing = 8
        let buttons = NSStackView(views: [back, undo, NSView(), nextPage, next])
        buttons.spacing = 6
        for v in [header, place, scroll, buttons, field] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sheet.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            sheet.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            sheet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            header.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 14),
            place.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            place.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            place.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: place.bottomAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -16),
        ])
        sheet.tape(at: 0.5, width: 58, angle: -2, seed: 404)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func submit() {
        let t = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        field.text = ""
        onSend?(t)
    }


    // MARK: Writing in the transcript

    private var body: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 4
        return [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: Theme.text, .paragraphStyle: p]
    }

    private func append(_ s: NSAttributedString) {
        guard let ts = transcript.textStorage else { return }
        ts.append(s)
        scrollToEnd()
    }

    private func scrollToEnd() {
        transcript.layoutManager?.ensureLayout(for: transcript.textContainer!)
        transcript.scrollToEndOfDocument(nil)
    }

    func clear() { transcript.string = ""; liveRange = nil }

    /// A small heading for a paragraph: where it is.
    func heading(_ text: String) {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 14
        p.paragraphSpacing = 4
        let lead = transcript.string.isEmpty ? "" : "\n"
        append(NSAttributedString(string: lead + text + "\n", attributes: [.font: Theme.mono(11), .foregroundColor: Theme.accent, .paragraphStyle: p]))
    }

    func note(_ text: String, color: NSColor = Theme.text3) {
        var a = body
        a[.foregroundColor] = color
        a[.font] = Theme.hand(14)
        append(NSAttributedString(string: text + "\n", attributes: a))
    }

    func author(_ text: String) {
        var a = body
        a[.foregroundColor] = Theme.sage
        a[.font] = Theme.hand(15)
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        p.paragraphSpacing = 6
        p.headIndent = 14
        p.firstLineHeadIndent = 0
        a[.paragraphStyle] = p
        append(NSAttributedString(string: "you  " + text + "\n", attributes: a))
    }

    /// Starts Claude's reply; `update` rewrites it as more arrives.
    func beginClaude() {
        guard let ts = transcript.textStorage else { return }
        if !(ts.string.hasSuffix("\n") || ts.string.isEmpty) { ts.append(NSAttributedString(string: "\n")) }
        liveRange = NSRange(location: ts.length, length: 0)
    }

    func updateClaude(_ visible: String) {
        guard let ts = transcript.textStorage, let r = liveRange else { return }
        let s = NSAttributedString(string: visible + "\n", attributes: body)
        ts.replaceCharacters(in: r, with: s)
        liveRange = NSRange(location: r.location, length: s.length)
        scrollToEnd()
    }

    func endClaude() { liveRange = nil }

    /// The paragraph before and after, word by word: gone words struck in red, new words in green.
    func showDiff(_ old: String, _ new: String) {
        let out = NSMutableAttributedString()
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacingBefore = 4
        p.paragraphSpacing = 8
        p.headIndent = 12
        p.firstLineHeadIndent = 12
        let base: [NSAttributedString.Key: Any] = [.font: Theme.mono(11.5), .foregroundColor: Theme.text2, .paragraphStyle: p]
        for part in WordDiff.diff(old, new) {
            var a = base
            switch part {
            case .same(let s):
                out.append(NSAttributedString(string: s, attributes: a))
            case .gone(let s):
                a[.foregroundColor] = Theme.clay
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                a[.strikethroughColor] = Theme.clay
                out.append(NSAttributedString(string: s, attributes: a))
            case .new(let s):
                a[.foregroundColor] = Theme.green
                a[.backgroundColor] = Theme.green.withAlphaComponent(0.13)
                out.append(NSAttributedString(string: s, attributes: a))
            }
        }
        out.append(NSAttributedString(string: "\n", attributes: base))
        append(out)
    }

    func setBusy(_ busy: Bool) {
        status.set(busy ? .working : .idle)
        for b in [back, undo, next, nextPage] { b.isEnabled = !busy }
        field.isEnabled = !busy
        field.placeholder = busy ? "Claude is reading…" : ReplyBox.hint
    }
}

// MARK: The reply box

/// Where the author writes to Claude: a few lines tall, growing with the
/// text up to about ten lines, inside a felt-pen outline. Return sends,
/// Shift-Return starts a new line.
final class ReplyBox: NSView, NSTextViewDelegate {
    static let hint = "Talk to Claude about this paragraph. Return sends, Shift-Return for a new line, Return on an empty box goes to the next paragraph."
    let scroll = NSScrollView()
    let textView = ReplyTextView()
    private let box = InkLayer()
    private var height: NSLayoutConstraint!
    var onSubmit: (() -> Void)?
    static let font = NSFont.systemFont(ofSize: 15)
    private let minLines: CGFloat = 4, maxLines: CGFloat = 10

    var text: String {
        get { textView.string }
        set { textView.string = newValue; textDidChange(Notification(name: NSText.didChangeNotification)) }
    }
    var placeholder: String = ReplyBox.hint { didSet { textView.placeholder = placeholder; textView.needsDisplay = true } }
    var isEnabled = true {
        didSet {
            textView.isEditable = isEnabled
            textView.textColor = isEnabled ? Theme.text : Theme.text3
            box.ink = isEnabled ? Theme.text2 : Theme.rule
            box.recolour()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        box.pen = Pen.fine.scaled(1.15)
        box.ink = Theme.text2
        box.owner = self
        box.seed = 5150
        layer?.addSublayer(box)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        textView.font = ReplyBox.font
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.accent
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.placeholder = placeholder
        textView.typingAttributes = [.font: ReplyBox.font, .foregroundColor: Theme.text]
        scroll.documentView = textView
        height = heightAnchor.constraint(equalToConstant: lineHeight * minLines + 24)
        NSLayoutConstraint.activate([
            height,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lineHeight: CGFloat { ceil(ReplyBox.font.ascender - ReplyBox.font.descender + ReplyBox.font.leading) + 1 }

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

    func textDidChange(_ notification: Notification) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let lines = min(maxLines, max(minLines, ceil(used / lineHeight)))
        height.constant = lineHeight * lines + 24
        textView.needsDisplay = true
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
                tv.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return true
        }
        return false
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(textView) }
}

/// The reply's text view: draws the hint while empty.
final class ReplyTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let inset = textContainerInset
        let pad = textContainer?.lineFragmentPadding ?? 5
        let r = NSRect(x: inset.width + pad, y: inset.height, width: bounds.width - 2 * (inset.width + pad), height: bounds.height - inset.height)
        (placeholder as NSString).draw(in: r, withAttributes: [.font: ReplyBox.font, .foregroundColor: Theme.text3])
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
}

// MARK: Running a pair session

final class PairController {
    unowned let wc: EditorWindowController
    let pane = PairPane()
    let model: PairModel
    private(set) var paragraphs: [PairParagraph] = []
    private(set) var current = 0
    private var claude: ClaudeSession?
    private var busy = false { didSet { pane.setBusy(busy) } }
    private var reply = ""
    private var appliedThisTurn = false
    private var history: [Int: [String]] = [:]
    private var changed: Set<Int> = []
    private var pendingNote: String?
    private(set) var active = false
    /// Probes: called whenever a reply has finished.
    var onIdle: (() -> Void)?
    /// The flat map of the last typeset run (SyncTeX speaks in its lines).
    private var shownMap: [SourceLine?] = []
    private var shownIndex: [SourceLine: Int] = [:]
    private var pageOf: [Int: Int] = [:]
    private var backupFolder: URL?

    static var modelChoice: String {
        get { UserDefaults.standard.string(forKey: "GalleyPairModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "GalleyPairModel") }
    }

    init(wc: EditorWindowController) {
        self.wc = wc
        let url = wc.doc.fileURL
        model = PairModel(mainKey: url?.path ?? "(untitled)", folder: url?.deletingLastPathComponent())
        pane.back.target = self; pane.back.action = #selector(goBack)
        pane.next.target = self; pane.next.action = #selector(goNext)
        pane.nextPage.target = self; pane.nextPage.action = #selector(goNextPage)
        pane.undo.target = self; pane.undo.action = #selector(undoChange)
        pane.modelButton.target = self; pane.modelButton.action = #selector(chooseModel(_:))
        pane.onSend = { [weak self] t in self?.authorSays(t) }
        refreshModelButton()
        pane.setBusy(false)
    }

    var main: String { wc.source.text.string }

    /// The text TeX should set while pairing, and where each line came from.
    func flatten() -> (text: String, map: [SourceLine?]) { model.flatten(main: main) }

    private func reparse() {
        let f = flatten()
        paragraphs = model.paragraphs(flat: f.text.components(separatedBy: "\n"), map: f.map)
        if current >= paragraphs.count { current = max(0, paragraphs.count - 1) }
    }

    func paragraphText(_ i: Int) -> String? {
        guard i < paragraphs.count else { return nil }
        let p = paragraphs[i]
        guard let text = model.text(of: p.file, main: main),
              let r = PairModel.lineRange(in: text, start: p.start, end: p.end) else { return nil }
        return (text as NSString).substring(with: r)
    }

    private func fileLabel(_ p: PairParagraph) -> String {
        p.file == model.mainKey ? (wc.doc.fileURL?.lastPathComponent ?? "Untitled") : (p.file as NSString).lastPathComponent
    }

    // MARK: Start and stop

    func start() {
        active = true
        reparse()
        guard !paragraphs.isEmpty else {
            pane.note("No paragraphs of prose were found in this document. Pair mode reads the text between \\begin{document} and \\end{document}, and the chapters it pulls in with \\input or \\include.", color: Theme.clay)
            return
        }
        startClaude()
        // Start where the reader is looking.
        if let page = wc.preview.pdf.currentPage, let doc = wc.preview.pdf.document, doc.index(for: page) > 0 {
            jumpToPage(doc.index(for: page), firstOnOrAfter: true)
        } else {
            current = 0
            review(current)
        }
    }

    func stop() {
        active = false
        claude?.stop()
        claude = nil
        busy = false
        wc.preview.clearMarks()
    }

    private func startClaude() {
        claude?.stop()
        let s = ClaudeSession()
        s.onText = { [weak self] t in self?.received(t) }
        s.onTurnEnd = { [weak self] err in self?.turnEnded(err) }
        s.onExit = { [weak self] why in
            guard let self else { return }
            self.busy = false
            self.claude = nil
            self.pane.note("Claude stopped: \(why)", color: Theme.clay)
        }
        do {
            try s.start(cwd: model.folder, systemPrompt: ClaudeSession.instructions, model: PairController.modelChoice)
            claude = s
        } catch {
            pane.note(error.localizedDescription, color: Theme.clay)
        }
    }

    private func send(_ text: String) {
        if claude == nil || !(claude?.isRunning ?? false) { startClaude() }
        guard let c = claude else { return }
        var t = text
        if let n = pendingNote { t = n + "\n\n" + t; pendingNote = nil }
        reply = ""
        appliedThisTurn = false
        busy = true
        pane.beginClaude()
        c.send(t)
    }

    // MARK: Moving

    @objc func goNext() {
        guard !busy, active else { return }
        if current + 1 >= paragraphs.count { pane.note("That was the last paragraph. Press ⌘S to keep the changes.", color: Theme.green); return }
        current += 1
        review(current)
    }

    @objc func goBack() {
        guard !busy, active, current > 0 else { return }
        current -= 1
        review(current)
    }

    /// Probes and the menu: the first paragraph on page `page` (0-based) or after.
    func goToPage(_ page: Int) { guard !busy, active else { return }; jumpToPage(page, firstOnOrAfter: true) }

    @objc func goNextPage() {
        guard !busy, active else { return }
        let page = pageOf[current] ?? 0
        jumpToPage(page + 1, firstOnOrAfter: true)
    }

    /// Goes to the first paragraph that starts on `page` or later.
    private func jumpToPage(_ page: Int, firstOnOrAfter: Bool) {
        guard let t = wc.typesetterForPair else { current = 0; review(0); return }
        let paras = paragraphs, idx = shownIndex
        let from = paras.indices.contains(current) && (pageOf[current] ?? 0) < page ? current : 0
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: Int?
            var pages: [Int: Int] = [:]
            for i in from..<paras.count {
                let p = paras[i]
                guard let flat = idx[SourceLine(file: p.file, line: p.start)],
                      let spot = t.syncView(line: flat + 1).first else { continue }
                pages[i] = spot.page
                if spot.page >= page { found = i; break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.pageOf.merge(pages) { $1 }
                guard let f = found else {
                    if self.current != 0 {
                        self.pane.note("No more paragraphs after this page.")
                    } else { self.review(0) }
                    return
                }
                self.current = f
                self.review(f)
            }
        }
    }

    /// The person clicked a spot on the pages; SyncTeX gave the flat line.
    func picked(flatLine: Int) {
        guard active, !busy, flatLine - 1 < shownMap.count, flatLine >= 1 else { return }
        guard let src = shownMap[flatLine - 1] else { return }
        if let i = paragraphs.firstIndex(where: { $0.file == src.file && $0.start <= src.line && src.line <= $0.end })
            ?? paragraphs.firstIndex(where: { $0.file == src.file && $0.start > src.line }) {
            if i == current { return }
            current = i
            review(i)
        }
    }

    // MARK: Reviewing one paragraph

    private func review(_ i: Int) {
        guard let text = paragraphText(i) else { return }
        let p = paragraphs[i]
        highlight { [weak self] page in
            guard let self, self.current == i else { return }
            let pageText = page.map { " · page \($0 + 1)" } ?? ""
            let place = "¶ \(i + 1) of \(self.paragraphs.count)\(pageText) · \(self.fileLabel(p)) l.\(p.start)–\(p.end)"
            self.pane.place.stringValue = place
            self.pane.heading(place)
            self.send("Paragraph \(i + 1) of \(self.paragraphs.count) · file \(self.fileLabel(p)), lines \(p.start)–\(p.end)\(pageText).\n\n```latex\n\(text)\n```")
        }
    }

    func authorSays(_ t: String) {
        guard active, !busy else { return }
        if t.isEmpty { goNext(); return }
        guard let text = paragraphText(current) else { return }
        pane.author(t)
        send("The author says: \(t)\n\nThe paragraph as it stands now:\n```latex\n\(text)\n```")
    }

    @objc func undoChange() {
        guard active, !busy, var stack = history[current], let prev = stack.popLast() else { NSSound.beep(); return }
        history[current] = stack
        guard let now = paragraphText(current) else { return }
        replace(current, with: prev)
        if stack.isEmpty { changed.remove(current) }
        pane.note("Put back the earlier version.")
        pane.showDiff(now, prev)
        pendingNote = "(The author undid your last change to this paragraph; it is back to the earlier version.)"
        wc.typeset(full: false)
    }

    // MARK: Claude's reply

    private func received(_ t: String) {
        reply += t
        pane.updateClaude(visible(reply))
        if !appliedThisTurn, let r = reply.range(of: "<revised>"), let e = reply.range(of: "</revised>", range: r.upperBound..<reply.endIndex) {
            appliedThisTurn = true
            apply(String(reply[r.upperBound..<e.lowerBound]))
        }
    }

    /// What the reader sees of the reply: the tags and the revised source are left out (the diff shows it).
    private func visible(_ s: String) -> String {
        var v = s
        if let r = v.range(of: "<revised>") {
            let tail = v[r.upperBound...]
            let after = tail.range(of: "</revised>").map { String(tail[$0.upperBound...]) } ?? ""
            v = String(v[..<r.lowerBound]) + after
        }
        v = v.replacingOccurrences(of: "<ok/>", with: "")
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func turnEnded(_ error: String?) {
        busy = false
        pane.endClaude()
        if let error { pane.note(error, color: Theme.clay); return }
        if !appliedThisTurn && reply.contains("<ok/>") {
            pane.note("✓ reads well", color: Theme.green)
        }
        let idle = onIdle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { idle?() }
    }

    private func apply(_ raw: String) {
        var new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if new.hasPrefix("```") {
            new = new.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if new.hasSuffix("```") { new = String(new.dropLast(3)) }
            new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A blank line would split the paragraph in two; keep it one.
        new = new.replacingOccurrences(of: "\\n[ \\t]*\\n+", with: "\n", options: .regularExpression)
        guard !new.isEmpty, let old = paragraphText(current) else { return }
        if new == old { pane.note("(no change)"); return }
        history[current, default: []].append(old)
        replace(current, with: new)
        changed.insert(current)
        pane.showDiff(old, new)
        wc.typeset(full: false)
    }

    private func replace(_ i: Int, with new: String) {
        let p = paragraphs[i]
        if p.file == model.mainKey {
            let tv = wc.source.text
            guard let r = PairModel.lineRange(in: tv.string, start: p.start, end: p.end) else { return }
            backUp(file: model.mainKey)
            if tv.shouldChangeText(in: r, replacementString: new) {
                tv.textStorage?.replaceCharacters(in: r, with: new)
                tv.didChangeText()
            }
        } else {
            guard let text = model.text(of: p.file, main: main),
                  let r = PairModel.lineRange(in: text, start: p.start, end: p.end) else { return }
            backUp(file: p.file)
            model.setChapter(p.file, text: (text as NSString).replacingCharacters(in: r, with: new))
            wc.doc.updateChangeCount(.changeDone)
        }
        let delta = new.components(separatedBy: "\n").count - (p.end - p.start + 1)
        reparse()
        _ = delta
    }

    /// The first change to a file in a session copies the file as it is on disk.
    private func backUp(file: String) {
        let path = file == model.mainKey ? wc.doc.fileURL?.path : file
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        if backupFolder == nil {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HHmmss"
            backupFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Galley/Pair backups/\(f.string(from: Date())) \(wc.doc.fileURL?.deletingPathExtension().lastPathComponent ?? "untitled")")
        }
        guard let dir = backupFolder else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((path as NSString).lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(atPath: path, toPath: dest.path) }
    }

    /// After ⌘S: chapters go to disk too.
    func saved() {
        guard let dir = backupFolder ?? Optional(FileManager.default.temporaryDirectory) else { return }
        let names = model.writeChapters(backup: dir)
        if !names.isEmpty { pane.note("Saved " + names.joined(separator: ", ") + ". The originals are in Galley's Pair backups folder.", color: Theme.green) }
    }

    // MARK: After each typeset

    func didTypeset(map: [SourceLine?], issues: [TeXIssue]) {
        shownMap = map
        shownIndex = [:]
        for (i, s) in map.enumerated() { if let s, shownIndex[s] == nil { shownIndex[s] = i } }
        pageOf = [:]
        if active {
            let errs = issues.filter { $0.kind == .error }
            if let e = errs.first {
                var whereText = ""
                if let l = e.line, l - 1 < map.count, l >= 1, let s = map[l - 1] {
                    whereText = " (\(s.file == model.mainKey ? (wc.doc.fileURL?.lastPathComponent ?? "") : (s.file as NSString).lastPathComponent) l.\(s.line))"
                }
                pane.note("TeX stopped: \(e.message)\(whereText). Undo change puts the paragraph back.", color: Theme.clay)
            }
            highlight(scroll: false) { _ in }
        }
    }

    /// Marks the current paragraph's lines on the pages and scrolls to them.
    /// Calls back with the page it starts on.
    private func highlight(scroll: Bool = true, then: @escaping (Int?) -> Void) {
        guard current < paragraphs.count, let t = wc.typesetterForPair else { then(nil); return }
        let p = paragraphs[current]
        let flats = (p.start...p.end).compactMap { shownIndex[SourceLine(file: p.file, line: $0)] }
        let tint = changed.contains(current) ? Theme.green.withAlphaComponent(0.32) : Theme.hi.withAlphaComponent(0.55)
        let i = current
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var spots: [Typesetter.ViewSpot] = []
            for f in flats { spots += t.syncView(line: f + 1) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.current == i else { return }
                let page = spots.map(\.page).min()
                if let page { self.pageOf[i] = page }
                self.wc.preview.mark(spots: spots, tint: tint, scroll: scroll)
                then(page)
            }
        }
    }

    // MARK: Model

    private func refreshModelButton() {
        let m = PairController.modelChoice
        pane.modelButton.title = m.isEmpty ? "default model" : m
        pane.modelButton.font = Theme.mono(11)
    }

    @objc func chooseModel(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, value) in [("Claude Code's default", ""), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku")] {
            let item = menu.addItem(withTitle: title, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = value == PairController.modelChoice ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func pickModel(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String, v != PairController.modelChoice else { return }
        PairController.modelChoice = v
        refreshModelButton()
        guard active else { return }
        claude?.stop()
        claude = nil
        busy = false
        pane.note("Switched to \(v.isEmpty ? "the default model" : v). Starting this paragraph again.")
        review(current)
    }
}

// MARK: Marking the pages

extension PreviewPane {
    func clearMarks() {
        guard let doc = pdf.document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a is MarkAnnotation { page.removeAnnotation(a) }
        }
    }

    /// Highlights the lines SyncTeX found, one stroke per printed line.
    func mark(spots: [Typesetter.ViewSpot], tint: NSColor, scroll: Bool) {
        clearMarks()
        guard let doc = pdf.document, !spots.isEmpty else { return }
        var first: (PDFPage, NSRect)?
        // Group by page and by column (two-column papers), then take the lines of text inside each group.
        var groups: [String: (PDFPage, NSRect)] = [:]
        for s in spots {
            guard let page = doc.page(at: s.page) else { continue }
            let pw = page.bounds(for: .mediaBox).width
            let r = pdf.pageRect(page: page, x: s.x, y: s.y, w: s.w, h: s.h)
            let col = r.width > pw * 0.55 ? "w" : (r.midX < pw / 2 ? "l" : "r")
            let key = "\(s.page)-\(col)"
            groups[key] = groups[key].map { ($0.0, $0.1.union(r)) } ?? (page, r)
        }
        for key in groups.keys.sorted(by: { a, b in
            let pa = Int(a.split(separator: "-")[0]) ?? 0, pb = Int(b.split(separator: "-")[0]) ?? 0
            return pa != pb ? pa < pb : a < b
        }) {
            guard let (page, area) = groups[key] else { continue }
            let probe = area.insetBy(dx: -2, dy: -3)
            var lines: [NSRect] = []
            if let sel = page.selection(for: probe) {
                for l in sel.selectionsByLine() {
                    let b = l.bounds(for: page)
                    guard b.width > 2, b.height > 2, area.insetBy(dx: -2, dy: -2).contains(NSPoint(x: b.midX, y: b.midY)) else { continue }
                    if let j = lines.firstIndex(where: { abs($0.midY - b.midY) < 2.5 }) { lines[j] = lines[j].union(b) } else { lines.append(b) }
                }
            }
            if lines.isEmpty { lines = [area] }
            for b in lines {
                let a = MarkAnnotation(bounds: b.insetBy(dx: -1.5, dy: -1), forType: .square, withProperties: nil)
                a.tint = tint
                a.shouldDisplay = true
                a.shouldPrint = false
                page.addAnnotation(a)
                if first == nil || (doc.index(for: page) < doc.index(for: first!.0)) || (first!.0 == page && b.maxY > first!.1.maxY) {
                    first = (page, b)
                }
            }
        }
        pdf.needsDisplay = true
        if scroll, let (page, r) = first {
            pdf.go(to: NSRect(x: r.minX, y: r.maxY - 200, width: r.width, height: 260), on: page)
        }
    }
}

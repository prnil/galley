import AppKit
import PDFKit

/// `Galley --selftest`: typesets real documents and checks the parts that
/// matter: errors land on the right lines, SyncTeX goes both ways, the
/// magic engine comment is read, \input files resolve from the source folder.
enum SelfTest {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("  ok    \(what)") } else { failed += 1; print("  FAIL  \(what)") }
    }

    static func typeset(_ t: Typesetter, _ text: String, engine: Engine = .pdflatex, full: Bool = false) -> TypesetResult {
        var out: TypesetResult?
        t.typeset(text, engine: engine, full: full) { out = $0 }
        let end = Date().addingTimeInterval(90)
        while out == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return out ?? TypesetResult(pdf: nil, issues: [], seconds: -1)
    }

    static func run() -> Bool {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("galley-selftest-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        print("Galley self-test in \(folder.path)")

        // 1. A clean document with an \input from the source folder and a citation.
        try? "This line comes from the chapter file.\n".write(to: folder.appendingPathComponent("chap.tex"), atomically: true, encoding: .utf8)
        try? "@book{knuth, author={Donald Knuth}, title={The TeXbook}, year={1984}, publisher={Addison-Wesley}}\n"
            .write(to: folder.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        let good = """
        \\documentclass{article}
        \\begin{document}
        \\section{Hello}
        Some text with maths $e^{i\\pi}+1=0$.

        \\input{chap}

        A citation \\cite{knuth}.
        \\bibliographystyle{plain}
        \\bibliography{refs}
        \\end{document}
        """
        let t = Typesetter(id: "selftest-\(UUID().uuidString)", name: "main doc", sourceFolder: folder)
        defer { try? fm.removeItem(at: t.dir) }
        check(t.job == "main_doc", "job name made safe (\(t.job))")
        var r = typeset(t, good)
        check(r.pdf != nil, "pdflatex makes a PDF (\(String(format: "%.2f", r.seconds)) s)")
        check(r.errors.isEmpty, "no errors on a good file \(r.errors.map(\.message))")
        check(!fm.fileExists(atPath: folder.appendingPathComponent("main doc.pdf").path) && !fm.fileExists(atPath: folder.appendingPathComponent("main_doc.aux").path),
              "nothing written into the source folder")
        r = typeset(t, good, full: true)
        check(r.pdf != nil && !r.warnings.contains { $0.message.contains("Citation") }, "full typeset runs BibTeX: citation resolved")
        let pdfText = r.pdf.flatMap { PDFDocumentText($0) } ?? ""
        check(pdfText.contains("comes from the chapter file"), "\\input found beside the source")
        check(pdfText.contains("Knuth"), "bibliography typeset")

        // 2. SyncTeX both ways.
        let spots = t.syncView(line: 4)
        check(!spots.isEmpty && spots[0].page == 0, "SyncTeX: line 4 found on page 1 (\(spots.count) boxes)")
        if let s = spots.first {
            let back = t.syncEdit(page: s.page, x: s.x + 5, y: s.y - 2)
            check(back?.line == 4 && back?.file == t.texCopy.path, "SyncTeX: that spot leads back to line 4 (got \(back.map { "\($0.line)" } ?? "nil"))")
        }

        // 3. Errors on the right lines; a PDF still comes out.
        let bad = """
        \\documentclass{article}
        \\begin{document}
        Fine line.

        \\badcommand here
        $x^2
        \\end{document}
        """
        r = typeset(t, bad)
        let lines = r.errors.compactMap(\.line)
        check(r.errors.contains { $0.line == 5 && $0.message.contains("Undefined control sequence") }, "undefined command reported on line 5 \(r.errors.map { "\($0.line ?? 0): \($0.message)" })")
        check(lines.allSatisfy { $0 >= 5 }, "no error lines before the mistake")
        check(r.errors.allSatisfy { $0.file == t.texCopy.path }, "errors attributed to the open file")

        // 4. Engines and the magic comment.
        check(Engine.magic(in: "% !TEX program = xelatex\n\\documentclass{article}") == .xelatex, "magic comment picks xelatex")
        check(Engine.magic(in: "%!TeX program=LuaLaTeX\n") == .lualatex, "magic comment, other spelling")
        check(Engine.magic(in: "\\documentclass{article}") == nil, "no magic comment, no override")
        r = typeset(t, "\\documentclass{article}\n\\usepackage{fontspec}\n\\begin{document}\nXe\\TeX\\ works.\n\\end{document}\n", engine: .xelatex)
        check(r.pdf != nil && r.errors.isEmpty, "xelatex typesets fontspec (\(String(format: "%.2f", r.seconds)) s)")

        // 5. Log parsing on a known log.
        let log = """
        ./main.tex:12: Undefined control sequence.
        l.12 \\foo

        LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 30.

        Overfull \\hbox (12.0pt too wide) in paragraph at lines 40--42
        ! Emergency stop.
        """
        let issues = Typesetter.parseLog(log, mainCopy: "/x/main.tex", folder: URL(fileURLWithPath: "/x"))
        check(issues.contains { $0.kind == .error && $0.line == 12 && $0.file == "/x/main.tex" }, "log: file:line error")
        check(issues.contains { $0.kind == .warning && $0.line == 30 && $0.message.contains("fig:x") }, "log: warning with input line")
        check(issues.contains { $0.kind == .badbox && $0.line == 40 }, "log: overfull box")

        // 6. Colouring.
        let ts = NSTextStorage(string: "\\section{Intro} text $a+b$ % note\n\\begin{equation}\nx\n\\end{equation}")
        let hl = TeXHighlighter()
        hl.colour(ts, in: NSRange(location: 0, length: ts.length))
        func colour(at i: Int) -> NSColor? { ts.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }
        check(colour(at: 1) == Theme.sage, "command in blue ink")
        check(ts.attribute(.galleyMarker, at: 10, effectiveRange: nil) != nil, "section title gets the highlighter")
        check(colour(at: 22) == Theme.accent, "inline maths in marker orange")
        check(colour(at: 29) == Theme.text3, "comment in pencil")
        check(colour(at: 51) == Theme.accent, "display maths body in marker orange")

        print("\(passed) passed, \(failed) failed")
        return failed == 0
    }

    static func PDFDocumentText(_ url: URL) -> String? { PDFDocument(url: url)?.string }
}

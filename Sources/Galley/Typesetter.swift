import Foundation

/// Runs TeX. The editor's text is written to a cache copy and typeset there,
/// with the working directory set to the source's own folder, so `\input`,
/// `\includegraphics` and `.bib` files resolve as if TeX ran beside the file.
/// Nothing is written into the person's folder until they save or export.

enum Engine: String, CaseIterable {
    case pdflatex, xelatex, lualatex, tectonic

    var title: String { rawValue }

    /// Tectonic is a separate install (Homebrew); it fetches missing packages itself.
    static let tectonicPath = ["/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static var installed: [Engine] { allCases.filter { $0 != .tectonic || tectonicPath != nil } }

    /// `% !TEX program = xelatex` (TeXShop / TeXstudio magic comment) in the first lines.
    static func magic(in text: String) -> Engine? {
        for line in text.split(separator: "\n", maxSplits: 25, omittingEmptySubsequences: false).prefix(25) {
            // Only a line that is itself the directive: "% !TEX program = xelatex".
            let l = line.lowercased().trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("%"), l.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("!tex"),
                  l.contains("program"), let eq = l.firstIndex(of: "=") else { continue }
            let name = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return Engine.allCases.first { name.hasPrefix($0.rawValue) }
        }
        return nil
    }
}

struct TeXIssue: Equatable {
    enum Kind { case error, warning, badbox }
    var kind: Kind
    /// Absolute path of the file the issue is in; nil when TeX did not say.
    var file: String?
    var line: Int?
    var message: String
}

struct TypesetResult {
    var pdf: URL?
    var issues: [TeXIssue]
    var seconds: Double
    var pages: Int = 0
    var ok: Bool { pdf != nil && !issues.contains { $0.kind == .error } }
    var errors: [TeXIssue] { issues.filter { $0.kind == .error } }
    var warnings: [TeXIssue] { issues.filter { $0.kind != .error } }
}

final class Typesetter {
    static let texbin = "/Library/TeX/texbin"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: texbin + "/pdflatex") }

    /// Cache folder for one document.
    let dir: URL
    /// Base name of the job: the source's name without extension, made safe.
    let job: String
    /// The source's folder (TeX's working directory), nil for an untitled document.
    var sourceFolder: URL?

    var texCopy: URL { dir.appendingPathComponent(job + ".tex") }
    var pdf: URL { dir.appendingPathComponent(job + ".pdf") }
    var log: URL { dir.appendingPathComponent(job + ".log") }

    private let queue = DispatchQueue(label: "galley.typeset")
    private var running: Process?
    private let lock = NSLock()

    init(id: String, name: String, sourceFolder: URL?) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("Galley/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        job = safe.isEmpty ? "galley" : safe
        self.sourceFolder = sourceFolder
    }

    /// Typesets `text`. `full` also runs BibTeX or Biber and the passes they need.
    /// Calls back on the main queue.
    func typeset(_ text: String, engine: Engine, full: Bool, done: @escaping (TypesetResult) -> Void) {
        queue.async { [self] in
            let start = Date()
            do { try text.write(to: texCopy, atomically: true, encoding: .utf8) } catch {
                let r = TypesetResult(pdf: nil, issues: [TeXIssue(kind: .error, file: nil, line: nil, message: "Could not write the draft copy: \(error.localizedDescription)")], seconds: 0)
                DispatchQueue.main.async { done(r) }
                return
            }
            mirrorIncludeFolders(text)
            var status = runEngine(engine)
            var logText = readLog()
            if full && status >= 0 && engine != .tectonic {
                let aux = (try? String(contentsOf: dir.appendingPathComponent(job + ".aux"), encoding: .utf8)) ?? ""
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent(job + ".bcf").path) {
                    _ = run("biber", [job], cwd: dir)
                } else if aux.contains("\\bibdata") {
                    _ = run("bibtex", [job], cwd: dir)
                }
                status = runEngine(engine)
                status = runEngine(engine)
                logText = readLog()
            } else if status >= 0, logText.contains("Rerun to get") || logText.contains("Label(s) may have changed") {
                // One more pass so references and the contents page settle while typing.
                status = runEngine(engine)
                logText = readLog()
            }
            var issues = Typesetter.parseLog(logText, mainCopy: texCopy.path, folder: sourceFolder ?? dir)
            if status == -2 {
                issues.insert(TeXIssue(kind: .error, file: nil, line: nil, message: "TeX took longer than 45 seconds and was stopped."), at: 0)
            }
            let havePDF = FileManager.default.fileExists(atPath: pdf.path)
            if !havePDF && issues.isEmpty {
                issues.append(TeXIssue(kind: .error, file: nil, line: nil, message: status == -1 ? "\(engine.rawValue) could not be started. Is MacTeX installed in /Library/TeX?" : "No PDF was produced."))
            }
            let r = TypesetResult(pdf: havePDF ? pdf : nil, issues: issues, seconds: Date().timeIntervalSince(start))
            DispatchQueue.main.async { done(r) }
        }
    }

    func cancel() {
        lock.lock(); running?.terminate(); lock.unlock()
    }

    // MARK: Running tools

    private func runEngine(_ e: Engine) -> Int32 {
        // The old PDF goes, so a failed run never shows a stale page as new.
        try? FileManager.default.removeItem(at: pdf)
        if e == .tectonic, let t = Engine.tectonicPath {
            // Tectonic runs BibTeX and the extra passes itself; -Z search-path stands in for TEXINPUTS.
            return run(t, ["-X", "compile", "--synctex", "--keep-logs", "--keep-intermediates", "-Z", "continue-on-errors",
                           "-Z", "search-path=\((sourceFolder ?? dir).path)", "--outdir", dir.path, texCopy.path],
                       cwd: sourceFolder ?? dir, timeout: 180)
        }
        return run(e.rawValue, ["-interaction=nonstopmode", "-file-line-error", "-synctex=1",
                                "-output-directory=\(dir.path)", "-jobname=\(job)", texCopy.path],
                   cwd: sourceFolder ?? dir, timeout: 45)
    }

    /// Runs a TeX Live tool. Returns its exit status, -1 when it could not start, -2 on timeout.
    @discardableResult
    func run(_ tool: String, _ args: [String], cwd: URL, timeout: Double = 30) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool.hasPrefix("/") ? tool : Typesetter.texbin + "/" + tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Typesetter.texbin + ":/usr/bin:/bin:" + (env["PATH"] ?? "")
        let folder = (sourceFolder ?? dir).path
        // Trailing colon: then TeX's own search path.
        env["TEXINPUTS"] = ".:\(folder)//:"
        env["BIBINPUTS"] = ".:\(folder)//:"
        env["BSTINPUTS"] = ".:\(folder)//:"
        // Unwrapped log lines, so messages are never split mid-word.
        env["max_print_line"] = "10000"
        env["error_line"] = "254"
        env["half_error_line"] = "238"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        lock.lock(); running = p; lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); p.waitUntilExit(); return -2 }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock(); running = nil; lock.unlock()
        return p.terminationStatus
    }

    /// `\include{chapters/one}` writes chapters/one.aux into the output folder,
    /// which TeX cannot do unless that folder exists.
    private func mirrorIncludeFolders(_ text: String) {
        guard let re = try? NSRegularExpression(pattern: "\\\\include\\{([^}]+)/[^}/]+\\}") else { return }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let sub = ns.substring(with: m.range(at: 1))
            guard !sub.contains("..") else { continue }
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    private func readLog() -> String {
        guard let d = try? Data(contentsOf: log) else { return "" }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    // MARK: The log

    /// Reads errors (from -file-line-error lines and `!` lines) and warnings
    /// out of a TeX log. Lines the main draft copy reports become `mainCopy`.
    static func parseLog(_ log: String, mainCopy: String, folder: URL) -> [TeXIssue] {
        var out: [TeXIssue] = []
        let lines = log.components(separatedBy: "\n")
        let fileLine = try! NSRegularExpression(pattern: "^(.*?\\.(?:tex|ltx|sty|cls|bbl|aux|def|cfg|clo)):(\\d+): (.*)$")
        let onLine = try! NSRegularExpression(pattern: "on input line (\\d+)")
        var i = 0
        func resolve(_ f: String) -> String {
            if f.hasSuffix("/" + (mainCopy as NSString).lastPathComponent) || f == mainCopy { return mainCopy }
            var p = f.hasPrefix("/") ? f : folder.appendingPathComponent(f).standardized.path
            // Tectonic names \input files without their extension.
            if (p as NSString).pathExtension.isEmpty, FileManager.default.fileExists(atPath: p + ".tex") { p += ".tex" }
            return p
        }
        // The file TeX is reading: "(./chap.tex" opens one, ")" closes it.
        var stack: [String] = []
        let opener = try! NSRegularExpression(pattern: "^(\\.{0,2}/[^\\s()]+|[^\\s()\\[\\]]+/[^\\s()\\[\\]]+|[^\\s()/]+\\.(?:tex|sty|cls|cfg|def|clo|fd|ltx|bbl))")
        func track(_ l: String) {
            let chars = Array(l.utf16)
            let ns = l as NSString
            var k = 0
            while k < chars.count {
                if chars[k] == 40 {   // (
                    let rest = NSRange(location: k + 1, length: ns.length - k - 1)
                    if let m = opener.firstMatch(in: l, options: .anchored, range: rest) {
                        stack.append(resolve(ns.substring(with: m.range(at: 1))))
                        k = NSMaxRange(m.range)
                        continue
                    }
                    stack.append("")   // a parenthesis in text, so the ")" that closes it pops the right thing
                } else if chars[k] == 41, !stack.isEmpty {   // )
                    stack.removeLast()
                }
                k += 1
            }
        }
        var current: String? { stack.last { !$0.isEmpty } }
        while i < lines.count {
            let l = lines[i]
            let ns = l as NSString
            if let m = fileLine.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                var msg = ns.substring(with: m.range(at: 3))
                // "l.12 \foo" context lines that follow add the offending text.
                if i + 1 < lines.count, msg.count < 30, !lines[i + 1].isEmpty, !lines[i + 1].hasPrefix("l."), !lines[i + 1].hasPrefix("<") {
                    msg += " " + lines[i + 1].trimmingCharacters(in: .whitespaces)
                }
                let issue = TeXIssue(kind: .error, file: resolve(ns.substring(with: m.range(at: 1))),
                                     line: Int(ns.substring(with: m.range(at: 2))), message: tidy(msg))
                if !out.contains(issue) { out.append(issue) }
            } else if l.hasPrefix("! ") {
                var line: Int?
                for j in (i + 1)..<min(lines.count, i + 12) where lines[j].hasPrefix("l.") {
                    line = Int(lines[j].dropFirst(2).prefix { $0.isNumber }); break
                }
                // Which file: a file:line line that follows for the same line number says; else the open file.
                var file: String? = line == nil ? nil : mainCopy
                if let n = line {
                    for j in (i + 1)..<min(lines.count, i + 30) {
                        let lj = lines[j] as NSString
                        if let m = fileLine.firstMatch(in: lines[j], range: NSRange(location: 0, length: lj.length)),
                           Int(lj.substring(with: m.range(at: 2))) == n { file = resolve(lj.substring(with: m.range(at: 1))); break }
                    }
                }
                if file == mainCopy, let c = current { file = c }
                let issue = TeXIssue(kind: .error, file: file, line: line, message: tidy(String(l.dropFirst(2))))
                if !out.contains(where: { $0.message == issue.message }) { out.append(issue) }
            } else if l.contains("Warning:") && (l.hasPrefix("LaTeX") || l.hasPrefix("Package") || l.hasPrefix("Class")) {
                // Warnings wrap over several lines; gather until a blank line.
                var text = l
                var j = i + 1
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty, j < i + 6 {
                    text += " " + lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                }
                let t = text as NSString
                let n = onLine.firstMatch(in: text, range: NSRange(location: 0, length: t.length)).map { Int(t.substring(with: $0.range(at: 1))) } ?? nil
                var msg = text.replacingOccurrences(of: "^(LaTeX|Package \\S+|Class \\S+) Warning: ", with: "", options: .regularExpression)
                msg = msg.replacingOccurrences(of: "\\(\\S+\\)\\s+", with: "", options: .regularExpression)
                out.append(TeXIssue(kind: .warning, file: n == nil ? nil : (current ?? mainCopy), line: n, message: tidy(msg)))
                for k in i..<j { track(lines[k]) }
                i = j
                continue
            } else if l.hasPrefix("Overfull \\hbox") || l.hasPrefix("Underfull \\hbox") {
                let t = l as NSString
                let r = try! NSRegularExpression(pattern: "at lines? (\\d+)")
                let n = r.firstMatch(in: l, range: NSRange(location: 0, length: t.length)).map { Int(t.substring(with: $0.range(at: 1))) } ?? nil
                out.append(TeXIssue(kind: .badbox, file: n == nil ? nil : (current ?? mainCopy), line: n,
                                    message: l.components(separatedBy: " in ").first ?? l))
            }
            track(l)
            i += 1
        }
        // TeX's sign-off lines say nothing the first error did not.
        let noise = ["Emergency stop", "==> Fatal error occurred", "job aborted"]
        let real = out.filter { i in !(i.kind == .error && noise.contains { i.message.contains($0) }) }
        let kept = real.contains { $0.kind == .error } ? real : out
        // A missing package: say how to get it.
        return kept.map { i in
            var i = i
            if i.kind == .error, let r = i.message.range(of: "File `([^']+\\.(sty|cls))' not found", options: .regularExpression) {
                let name = i.message[r].split(separator: "`")[1].split(separator: "'")[0]
                let pkg = (name as Substring).split(separator: ".")[0]
                i.message = "\(name) is not installed. Try the tectonic engine, which fetches packages, or run: sudo tlmgr install \(pkg)"
            }
            return i
        }.reduce(into: [TeXIssue]()) { acc, i in if !acc.contains(i) { acc.append(i) } }
    }

    private static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("LaTeX Error: ") { t.removeFirst(13) }
        if t.count > 180 { t = String(t.prefix(177)) + "…" }
        return t
    }

    // MARK: SyncTeX

    struct ViewSpot { var page: Int; var x: Double; var y: Double; var w: Double; var h: Double }

    /// Source line → place on the page (`synctex view`). Coordinates are
    /// TeX's: big points from the page's top-left, y at the baseline.
    func syncView(line: Int, column: Int = 0, file: String? = nil) -> [ViewSpot] {
        let out = capture("synctex", ["view", "-i", "\(line):\(column):\(file ?? texCopy.path)", "-o", pdf.path])
        var spots: [ViewSpot] = []
        var cur: [String: Double] = [:]
        func flush() {
            if let p = cur["Page"], let h = cur["h"], let v = cur["v"] {
                spots.append(ViewSpot(page: Int(p) - 1, x: h, y: v, w: cur["W"] ?? 0, h: cur["H"] ?? 0))
            }
            cur = [:]
        }
        for l in out.split(separator: "\n") {
            let parts = l.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = String(parts[0]), v = Double(parts[1].trimmingCharacters(in: .whitespaces))
            if k == "Page" { flush() }
            if let v { cur[k] = v }
        }
        flush()
        return spots
    }

    /// Place on the page → source file and line (`synctex edit`). `y` from the top.
    func syncEdit(page: Int, x: Double, y: Double) -> (file: String, line: Int)? {
        let out = capture("synctex", ["edit", "-o", "\(page + 1):\(x):\(y):\(pdf.path)"])
        var file: String?, line: Int?
        for l in out.split(separator: "\n") {
            if l.hasPrefix("Input:") { file = String(l.dropFirst(6)) }
            if l.hasPrefix("Line:"), line == nil { line = Int(l.dropFirst(5)) }
        }
        guard var f = file, let n = line else { return nil }
        f = (f as NSString).standardizingPath
        if f.hasPrefix(dir.path) || (f as NSString).lastPathComponent == texCopy.lastPathComponent { f = texCopy.path }
        return (f, n)
    }

    private func capture(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Typesetter.texbin + "/" + tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

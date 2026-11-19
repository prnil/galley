import AppKit
import PDFKit

enum Prefs {
    /// True for --selftest and --snapshot runs: no animations, nothing written to Open Recent.
    static var probing = false

    static var liveTypeset: Bool {
        get { UserDefaults.standard.register(defaults: ["GalleyLiveTypeset": true]); return UserDefaults.standard.bool(forKey: "GalleyLiveTypeset") }
        set { UserDefaults.standard.set(newValue, forKey: "GalleyLiveTypeset") }
    }
    /// Off by default: saving writes only the .tex; Export PDF writes the PDF.
    static var pdfBesideOnSave: Bool {
        get { UserDefaults.standard.bool(forKey: "GalleyPDFBeside") }
        set { UserDefaults.standard.set(newValue, forKey: "GalleyPDFBeside") }
    }
    static var defaultEngine: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: "GalleyEngine") ?? "") ?? .pdflatex }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "GalleyEngine") }
    }
}

/// A TeX (or BibTeX, .sty, .cls) source file.
@objc(TeXDocument)
final class TeXDocument: NSDocument {
    var text: String = ""
    /// Set by the window: reads the live text out of the editor.
    var liveText: (() -> String)?

    override class var autosavesInPlace: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    /// Only .tex files are typeset; .bib, .sty and .cls are just edited.
    var isTypesettable: Bool {
        guard let ext = fileURL?.pathExtension.lowercased() else { return true }
        return ["tex", "ltx", "latex"].contains(ext)
    }
    var isBib: Bool { fileURL?.pathExtension.lowercased() == "bib" }

    override init() {
        super.init()
        if let url = Theme.resources?.appendingPathComponent("Templates/Starter.tex"),
           let t = try? String(contentsOf: url, encoding: .utf8) {
            text = t
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if let s = String(data: data, encoding: .utf8) { text = s }
        else if let s = String(data: data, encoding: .isoLatin1) { text = s }
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    }

    override func data(ofType typeName: String) throws -> Data {
        let t = liveText?() ?? text
        text = t
        return Data(t.utf8)
    }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] err in
            completionHandler(err)
            guard err == nil, let self else { return }
            (self.windowControllers.first as? EditorWindowController)?.documentSaved()
        }
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { ["TeX Source", "TeX Support File"] }
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        fileURL?.pathExtension ?? "tex"
    }
}

/// A PDF opened only to read.
@objc(PDFReadDocument)
final class PDFReadDocument: NSDocument {
    var pdfURL: URL?
    override class var autosavesInPlace: Bool { false }
    override func read(from url: URL, ofType typeName: String) throws { pdfURL = url }
    override func makeWindowControllers() { addWindowController(ReaderWindowController(document: self)) }
    override func data(ofType typeName: String) throws -> Data { throw CocoaError(.featureUnsupported) }
    override var isDocumentEdited: Bool { false }
}

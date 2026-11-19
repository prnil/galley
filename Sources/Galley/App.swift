import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    /// Draft caches left by runs that ended without closing their window.
    private func sweepCaches() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Galley")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for d in dirs {
            let name = d.lastPathComponent
            if let pid = name.split(separator: "-").last.flatMap({ Int32($0) }), name.count < 30 {
                if kill(pid, 0) != 0 { try? FileManager.default.removeItem(at: d) }
            } else if let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      m < Date().addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: d)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sweepCaches()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            Snapshot.run(Array(CommandLine.arguments[(i + 1)...]))
            return
        }
        // Files given on the command line (after any flags).
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        for f in files {
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: f), display: true) { _, _, _ in }
        }
    }

    /// Like MacDown: a fresh page when the app opens with nothing else.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !Prefs.probing }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func toggleAnimations(_ sender: NSMenuItem) { Motion.userSetting.toggle() }
    @objc func toggleFollowSystem(_ sender: NSMenuItem) { Theme.followSystem.toggle() }
    @objc func openTeXLog(_ sender: Any?) {
        NSWorkspace.shared.open(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Galley"))
    }

    @objc func showHelp(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Galley"
        a.informativeText = """
        Write on the left; the typeset pages appear on the right as you pause.

        ⌘-click the pages to jump to that line of source.
        ⌘-click the source (or ⌘J) to circle it on the pages.
        ⌘B typesets with BibTeX or Biber. ⌘' goes to the next error.
        A line like  % !TEX program = xelatex  at the top picks the engine.

        Your file is written only when you save. The PDF stays in Galley's cache until you Export PDF (⌘E), or turn on Typeset › Write PDF Beside Source on Save.
        """
        a.runModal()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAnimations(_:)) { item.state = Motion.userSetting ? .on : .off }
        if item.action == #selector(toggleFollowSystem(_:)) { item.state = Theme.followSystem ? .on : .off }
        return true
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let d = NSApp.delegate as AnyObject

        sub("Galley", [
            item("About Galley", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Galley", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Galley", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let rm = NSMenu(title: "Open Recent")
        rm.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = rm
        rm.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        sub("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recent,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Export PDF…", #selector(EditorWindowController.exportPDF(_:)), "e"),
            item("Print…", #selector(EditorWindowController.printDocument(_:)), "p"),
        ])

        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let fm = NSMenu(title: "Find")
        for (t, tag, k, mods) in [("Find…", 1, "f", NSEvent.ModifierFlags.command), ("Find and Replace…", 12, "f", [.command, .option]),
                                  ("Find Next", 2, "g", .command), ("Find Previous", 3, "g", [.command, .shift]),
                                  ("Use Selection for Find", 7, "e", [.command, .option])] {
            let i = item(t, #selector(NSTextView.performFindPanelAction(_:)), k, mods)
            i.tag = tag
            fm.addItem(i)
        }
        find.submenu = fm
        sub("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find,
            item("Comment or Uncomment Lines", #selector(EditorWindowController.toggleComment(_:)), "/"),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        ])

        sub("Typeset", [
            item("Typeset Now", #selector(EditorWindowController.typesetNow(_:)), "r"),
            item("Typeset with Bibliography", #selector(EditorWindowController.typesetFull(_:)), "b"),
            item("Typeset While Typing", #selector(EditorWindowController.toggleLive(_:))),
            .separator(),
            item("Show Line in Pages", #selector(EditorWindowController.showInPDFAction(_:)), "j"),
            item("Next Error", #selector(EditorWindowController.nextIssue(_:)), "'"),
            item("Show What TeX Said", #selector(EditorWindowController.showIssues(_:)), "l", [.command, .shift]),
            .separator(),
            item("Write PDF Beside Source on Save", #selector(EditorWindowController.togglePDFBeside(_:))),
            item("Open Typesetting Cache", #selector(AppDelegate.openTeXLog(_:)), target: d),
        ])

        let enterFS = item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        sub("View", [
            item("Source", #selector(EditorWindowController.layoutSource(_:)), "1"),
            item("Source and Pages", #selector(EditorWindowController.layoutBoth(_:)), "2"),
            item("Pages", #selector(EditorWindowController.layoutPages(_:)), "3"),
            .separator(),
            item("Zoom In", #selector(EditorWindowController.zoomInPages(_:)), "="),
            item("Zoom Out", #selector(EditorWindowController.zoomOutPages(_:)), "-"),
            item("Fit Page Width", #selector(EditorWindowController.fitPages(_:)), "0"),
            .separator(),
            item("Bigger Text", #selector(EditorWindowController.biggerText(_:)), "=", [.command, .option]),
            item("Smaller Text", #selector(EditorWindowController.smallerText(_:)), "-", [.command, .option]),
            item("Line Numbers", #selector(EditorWindowController.toggleNumbers(_:))),
            .separator(),
            item("Animations", #selector(AppDelegate.toggleAnimations(_:)), target: d),
            item("Follow System Dark Mode", #selector(AppDelegate.toggleFollowSystem(_:)), target: d),
            .separator(),
            enterFS,
        ])

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        let wHost = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        wHost.submenu = windowMenu
        main.addItem(wHost)
        NSApp.windowsMenu = windowMenu

        sub("Help", [item("Galley Help", #selector(AppDelegate.showHelp(_:)), "?", target: d)])
        return main
    }
}

final class GalleyDocumentController: NSDocumentController {
    override func noteNewRecentDocumentURL(_ url: URL) {
        guard !Prefs.probing else { return }
        super.noteNewRecentDocumentURL(url)
    }
}

// MARK: Snapshot (checking the look without driving the screen)

/// `Galley --snapshot <in.tex|in.pdf> <out.png> [layout=0|1|2] [sync=<line>] [edit=<page>:<x>:<y>]
///  [type=<text>] [shot=<seconds>] [dark] [motion] [size=WxH]`
enum Snapshot {
    static func run(_ args: [String]) {
        guard args.count >= 2 else { print("usage: --snapshot in out.png …"); exit(2) }
        let input = URL(fileURLWithPath: args[0]), out = args[1]
        func opt(_ k: String) -> String? { args.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
        if args.contains("motion") { Motion.forceOn = true }
        if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let shot = Double(opt("shot") ?? "") ?? 0.4
        NSDocumentController.shared.openDocument(withContentsOf: input, display: true) { d, _, err in
            guard let d else { print("snapshot: could not open: \(err?.localizedDescription ?? "?")"); exit(1) }
            let window = d.windowControllers.first?.window
            if let s = opt("size")?.split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) {
                window?.setFrame(NSRect(x: 40, y: 40, width: w, height: h), display: true)
            }
            if let wc = d.windowControllers.first as? ReaderWindowController {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { capture(wc.window, to: out) }
                return
            }
            guard let wc = d.windowControllers.first as? EditorWindowController else { exit(1) }
            if let l = opt("layout").flatMap(Int.init).flatMap(Layout.init) { wc.setLayout(l, animated: false) }
            var actedType = false
            wc.onTypeset = { r in
                print("typeset: pdf=\(r.pdf != nil) pages=\(r.pages) errors=\(r.errors.count) warnings=\(r.warnings.count) \(String(format: "%.2f", r.seconds))s")
                for i in r.issues.prefix(8) { print("  \(i.kind) \(i.file.map { ($0 as NSString).lastPathComponent } ?? "-"):\(i.line ?? 0) \(i.message)") }
                if let t = opt("type"), !actedType {
                    // Type at the end of the document, then wait for the live typeset.
                    actedType = true
                    let tv = wc.source.text
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    tv.insertText(t.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: tv.selectedRange())
                    return
                }
                if let l = opt("sync").flatMap(Int.init) {
                    wc.showInPDF(line: l)
                }
                if let e = opt("edit")?.split(separator: ":").compactMap({ Double($0) }), e.count == 3 {
                    wc.preview.pdf.onSyncEdit?(Int(e[0]), e[1], e[2])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("edit: caret on line \(wc.source.text.currentLine)") }
                }
                if args.contains("save") { wc.documentSaved() }
                DispatchQueue.main.asyncAfter(deadline: .now() + shot) { capture(wc.window, to: out) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("snapshot: timed out"); exit(1) }
    }

    static func capture(_ window: NSWindow?, to path: String) {
        guard let window else { exit(1) }
        typealias Shot = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") {
            let shot = unsafeBitCast(sym, to: Shot.self)
            if let img = shot(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue(), img.width > 10 {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot: wrote \(path) (\(img.width)x\(img.height))")
                exit(0)
            }
        }
        // Fallback: ask the views to draw themselves.
        guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(1) }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot: wrote \(path) (views)")
        exit(0)
    }
}

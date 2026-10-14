import AppKit

final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalViewDelegate {
    let terminalView: TerminalView
    let page: PageView
    var onClose: ((TerminalWindowController) -> Void)?
    private var statusTimer: Timer?
    private var layoutObservation: NSKeyValueObservation?
    private var theme: Theme
    private var lastDirectory: String?

    init(cwd: String?, theme: Theme) {
        self.theme = theme
        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: theme)
        page = PageView(content: terminalView)

        let cfg = Config.shared
        let grid = terminalView.sizeFor(cols: cfg.columns, rows: cfg.rows)
        let size = NSSize(width: grid.width,
                          height: grid.height + PageView.chromeHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ghosty"
        window.minSize = NSSize(width: 420, height: 260)
        window.contentView = page
        window.center()
        window.setFrameAutosaveName("")

        super.init(window: window)
        window.delegate = self
        terminalView.delegate = self
        page.masthead.onHeadlineClick = { [weak self] rect in self?.showFolderMenu(at: rect) }
        page.pathBar.onNavigate = { [weak self] path in self?.go(to: path) }
        page.pathBar.onCancel = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.terminalView)
        }
        applyTheme(theme)

        page.layoutSubtreeIfNeeded()
        terminalView.start(cwd: cwd)
        window.makeFirstResponder(terminalView)
        refreshStatus()

        layoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            self?.page.needsLayout = true
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        page.theme = theme
        page.masthead.theme = theme
        page.footer.theme = theme
        page.masthead.edition = Config.shared.editionName
        page.masthead.margin = Config.shared.paddingX
        page.pathBar.theme = theme
        page.pathBar.margin = Config.shared.paddingX
        page.footer.margin = Config.shared.paddingX
        terminalView.theme = theme
        window?.backgroundColor = theme.paper
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    func applyConfig(theme: Theme) {
        terminalView.applyConfig()
        applyTheme(theme)
        page.needsLayout = true
    }

    // MARK: Status

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func refreshStatus() {
        guard let pty = terminalView.pty else { return }
        let term = terminalView.terminal
        let shellName = (pty.shellPath as NSString).lastPathComponent
        let fg = pty.foregroundProcessName
        let fullDir = pty.currentDirectory
        if let fullDir, fullDir != lastDirectory {
            lastDirectory = fullDir
            RecentDirectories.add(fullDir)
        }
        let dir = fullDir.map(TerminalWindowController.abbreviate) ?? "~"
        if let fullDir { page.pathBar.path = fullDir }
        let running = fg.map { $0 != shellName && $0 != "-" + shellName && $0 != "login" } ?? false

        let m = page.masthead
        let title = term.title.trimmingCharacters(in: .whitespaces)
        if running, let fg {
            m.kicker = "Now running"
            m.kickerIsLive = true
            m.headline = fg
            m.dek = title.isEmpty || title == fg ? "in \(dir)" : title
        } else {
            let leaf = dir == "~" || dir == "/" ? dir : (dir as NSString).lastPathComponent
            let parent = (dir as NSString).deletingLastPathComponent
            m.kicker = "The shell · \(shellName)"
            m.kickerIsLive = false
            m.headline = leaf
            if !title.isEmpty && !title.contains(leaf) {
                m.dek = title
            } else if leaf == dir || parent.isEmpty {
                m.dek = "set in \(fontLabel)"
            } else {
                m.dek = "in \(parent)"
            }
        }

        let f = page.footer
        f.left = "§ \(shellName) · pid \(pty.pid)"
        let index = (window?.tabbedWindows?.firstIndex(of: window!) ?? 0) + 1
        f.center = "— Page \(index) —"
        if terminalView.scrollOffset > 0 {
            f.right = "↑ \(terminalView.scrollOffset) lines back"
            f.rightIsAlert = true
        } else {
            f.right = "\(term.cols) × \(term.rows) · live"
            f.rightIsAlert = false
        }
        window?.title = m.headline
    }

    private var fontLabel: String {
        let name = Config.shared.fontFamily ?? "SF Mono"
        let size = terminalView.fontSize
        return "\(name) \(size.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(size)) : String(format: "%.1f", size))pt"
    }

    // MARK: Choosing a directory

    var currentDirectory: String? { terminalView.pty?.currentDirectory }

    /// Change into `path` if the shell is free; otherwise open it in a new tab.
    private func go(to path: String) {
        if terminalView.isShellIdle {
            page.pathBar.path = path
            terminalView.changeDirectory(to: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshStatus() }
        } else {
            (NSApp.delegate as? AppDelegate)?.openTab(at: path)
        }
    }

    private func folderItem(_ path: String, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? RecentDirectories.abbreviate(path),
                              action: #selector(jumpToFolder(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = path
        item.image = RecentDirectories.icon(for: path)
        item.toolTip = path
        if path == currentDirectory { item.state = .on }
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func showFolderMenu(at rect: NSRect) {
        let menu = NSMenu()
        let cwd = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let busy = !terminalView.isShellIdle

        if busy {
            menu.addItem(header("Shell is busy — folders open in a new tab"))
        }

        // Enclosing folders, nearest first.
        menu.addItem(header("Enclosing Folders"))
        var parent = cwd
        var depth = 0
        while parent != "/" && depth < 8 {
            parent = (parent as NSString).deletingLastPathComponent
            let name = parent == "/" ? "Macintosh HD" : (parent as NSString).lastPathComponent
            menu.addItem(folderItem(parent, title: name))
            depth += 1
        }

        let subfolders = ((try? FileManager.default.contentsOfDirectory(atPath: cwd)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .filter { var d: ObjCBool = false
                      return FileManager.default.fileExists(atPath: cwd + "/" + $0, isDirectory: &d) && d.boolValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !subfolders.isEmpty {
            menu.addItem(.separator())
            let sub = NSMenu()
            for name in subfolders.prefix(200) { sub.addItem(folderItem(cwd + "/" + name, title: name)) }
            let item = NSMenuItem(title: "Subfolders", action: nil, keyEquivalent: "")
            item.submenu = sub
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }

        let recents = RecentDirectories.all.filter { $0 != cwd }
        if !recents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Recent"))
            recents.prefix(8).forEach { menu.addItem(folderItem($0)) }
        }

        menu.addItem(.separator())
        menu.addItem(header("Places"))
        RecentDirectories.places.forEach { menu.addItem(folderItem($0)) }

        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Go to Folder…", action: #selector(goToFolder(_:)), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)
        let newTab = NSMenuItem(title: "Open Folder in New Tab…", action: #selector(openFolderInNewTab(_:)), keyEquivalent: "o")
        newTab.keyEquivalentModifierMask = [.command, .shift]
        newTab.target = self
        menu.addItem(newTab)
        let finder = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        finder.target = self
        menu.addItem(finder)

        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: page.masthead)
    }

    @objc private func jumpToFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        go(to: path)
    }

    private func pickFolder(prompt: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Choose a folder for this page."
        if let cwd = currentDirectory { panel.directoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url.path)
        }
    }

    @objc func goToFolder(_ sender: Any?) {
        pickFolder(prompt: "Go") { [weak self] path in self?.go(to: path) }
    }

    @objc func openFolderInNewTab(_ sender: Any?) {
        pickFolder(prompt: "Open") { path in (NSApp.delegate as? AppDelegate)?.openTab(at: path) }
    }

    @objc func editPath(_ sender: Any?) {
        page.pathBar.beginEditing()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let cwd = currentDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    /// Lists the largest files on the whole system, biggest first. Skips other volumes,
    /// devices and swap; files the user can't read are silently left out.
    static let biggestFilesCommand = #"""
        find / \( -path /Volumes -o -path /System/Volumes -o -path /dev -o -path /private/var/vm \) -prune \
        -o -type f -size +100M -exec stat -f '%z%t%N' {} + 2>/dev/null | sort -rn | head -n 50 \
        | awk -F'\t' '{ s = $1; u = "B"; split("KB MB GB TB", U, " "); for (i = 1; s >= 1024 && i <= 4; i++) { s /= 1024; u = U[i] } printf "%8.1f %s  %s\n", s, u, $2 }'
        """#.replacingOccurrences(of: " \\\n", with: " ")

    /// Runs the search here if the shell is free; otherwise in a new tab.
    @objc func findBiggestFiles(_ sender: Any?) {
        let target = terminalView.isShellIdle
            ? terminalView
            : (NSApp.delegate as? AppDelegate)?.openTab(at: currentDirectory).terminalView
        target?.runCommand(Self.biggestFilesCommand)
    }

    // MARK: TerminalViewDelegate

    func terminalViewStateDidChange(_ view: TerminalView) { refreshStatus() }

    func terminalViewProcessDidExit(_ view: TerminalView) {
        window?.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        terminalView.shutdown()
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshStatus() }

    /// The "+" button in the native tab bar.
    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(sender)
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [TerminalWindowController] = []
    private var appearanceObservation: NSKeyValueObservation?

    private var currentTheme: Theme {
        Theme.resolve(Config.shared.theme, appearance: NSApp.effectiveAppearance)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.shared.load()
        NSApp.mainMenu = buildMenu()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(forName: Config.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyConfig()
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyConfig() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.terminalView.shutdown() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    private func applyConfig() {
        let theme = currentTheme
        controllers.forEach { $0.applyConfig(theme: theme) }
    }

    // MARK: Windows

    private var activeController: TerminalWindowController? {
        controllers.first { $0.window === NSApp.keyWindow } ?? controllers.last
    }

    private func makeController(cwd: String?) -> TerminalWindowController {
        let c = TerminalWindowController(cwd: cwd, theme: currentTheme)
        c.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(c)
        return c
    }

    @objc func newWindow(_ sender: Any?) {
        let cwd = activeController?.terminalView.pty?.currentDirectory
        let c = makeController(cwd: cwd)
        if let key = NSApp.keyWindow {
            c.window?.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28))
        }
        c.showWindow(nil)
    }

    @objc func newTab(_ sender: Any?) {
        openTab(at: activeController?.terminalView.pty?.currentDirectory)
    }

    @discardableResult
    func openTab(at cwd: String?) -> TerminalWindowController {
        let parent = activeController?.window
        let c = makeController(cwd: cwd)
        guard let parent, let w = c.window else {
            c.showWindow(nil)
            return c
        }
        parent.addTabbedWindow(w, ordered: .above)
        w.makeKeyAndOrderFront(nil)
        return c
    }

    @objc func openConfig(_ sender: Any?) {
        Config.shared.ensureFile()
        let url = Config.shared.url
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func reloadConfig(_ sender: Any?) {
        Config.shared.reload()
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Config.shared.update("theme", id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectTheme(_:)), let id = item.representedObject as? String {
            item.state = Config.shared.theme.lowercased() == id ? .on : .off
        }
        return true
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A terminal set in type, printed on paper.\nAll the news that fits in 80 columns.",
            attributes: [.font: Theme.serif(11, weight: .regular, italic: true),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Ghosty",
            .applicationVersion: "1.0",
            .credits: credits,
        ])
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        // App
        let app = NSMenu(title: "Ghosty")
        app.addItem(item("About Ghosty", #selector(showAbout(_:)), target: self))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(openConfig(_:)), ",", target: self))
        app.addItem(item("Reload Configuration", #selector(reloadConfig(_:)), ",", [.command, .shift], target: self))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item("Hide Ghosty", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Ghosty", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(withSubmenu: app)

        // Shell
        let shell = NSMenu(title: "Shell")
        shell.addItem(item("New Window", #selector(newWindow(_:)), "n", target: self))
        shell.addItem(item("New Tab", #selector(newTab(_:)), "t", target: self))
        shell.addItem(.separator())
        shell.addItem(item("Type a Path…", #selector(TerminalWindowController.editPath(_:)), "l"))
        shell.addItem(item("Go to Folder…", #selector(TerminalWindowController.goToFolder(_:)), "o"))
        shell.addItem(item("Open Folder in New Tab…", #selector(TerminalWindowController.openFolderInNewTab(_:)), "o", [.command, .shift]))
        shell.addItem(item("Reveal in Finder", #selector(TerminalWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        shell.addItem(.separator())
        shell.addItem(item("Find Biggest Files", #selector(TerminalWindowController.findBiggestFiles(_:)), "b", [.command, .shift]))
        shell.addItem(.separator())
        shell.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        main.addItem(withSubmenu: shell)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", #selector(TerminalView.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(TerminalView.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Clear Page", #selector(TerminalView.clearBuffer(_:)), "k"))
        main.addItem(withSubmenu: edit)

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Bigger Type", #selector(TerminalView.increaseFontSize(_:)), "="))
        view.addItem(item("Smaller Type", #selector(TerminalView.decreaseFontSize(_:)), "-"))
        view.addItem(item("Actual Size", #selector(TerminalView.resetFontSize(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Scroll to Top", #selector(TerminalView.scrollToTop(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]))
        view.addItem(item("Scroll to Bottom", #selector(TerminalView.scrollToBottom(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]))
        view.addItem(.separator())
        let editions = NSMenu(title: "Edition")
        let choices: [(String, String)] = [("Follow System", "auto"), ("Broadsheet", "broadsheet"),
                                           ("Night Edition", "night"), ("Wired", "wired")]
        for (i, (title, id)) in choices.enumerated() {
            let it = item(title, #selector(selectTheme(_:)), i == 0 ? "" : String(i), [.command, .control], target: self)
            it.representedObject = id
            editions.addItem(it)
            if i == 0 { editions.addItem(.separator()) }
        }
        let editionItem = NSMenuItem(title: "Edition", action: nil, keyEquivalent: "")
        editionItem.submenu = editions
        view.addItem(editionItem)
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(withSubmenu: view)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]))
        window.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        main.addItem(withSubmenu: window)

        return main
    }
}

private extension NSMenu {
    func addItem(withSubmenu submenu: NSMenu) {
        let i = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        addItem(i)
    }
}

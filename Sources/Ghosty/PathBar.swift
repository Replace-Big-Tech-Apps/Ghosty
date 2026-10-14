import AppKit

/// A slim breadcrumb under the masthead: click a folder to go there, or click the
/// bar (⌘L) to type a path with Tab completion.
final class PathBar: NSView, NSTextFieldDelegate {
    var theme: Theme = .broadsheet { didSet { styleField(); needsDisplay = true } }
    var margin: CGFloat = 30 { didSet { needsLayout = true; needsDisplay = true } }
    var path = "" { didSet { if path != oldValue { needsDisplay = true } } }
    /// Called with an absolute, existing directory.
    var onNavigate: ((String) -> Void)?
    /// Called when editing ends without navigating, so focus can return to the terminal.
    var onCancel: (() -> Void)?

    private let field = NSTextField()
    private var segments: [(rect: NSRect, path: String)] = []
    private var editButtonRect = NSRect.zero
    private var hovered: Int?
    private var invalid = false
    private(set) var isEditing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        styleField()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: margin, y: (bounds.height - 18) / 2, width: bounds.width - margin * 2 - 70, height: 18)
    }

    private func styleField() {
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = theme.ink
    }

    // MARK: Editing

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        invalid = false
        field.stringValue = RecentDirectories.abbreviate(path) + (path == "/" ? "" : "/")
        field.isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func endEditing() {
        isEditing = false
        field.isHidden = true
        needsDisplay = true
    }

    private func expand(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("~") { t = FileManager.default.homeDirectoryForCurrentUser.path + t.dropFirst() }
        if !t.hasPrefix("/") { t = (path as NSString).appendingPathComponent(t) }
        return (t as NSString).standardizingPath
    }

    private func submit() {
        let target = expand(field.stringValue)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            invalid = true
            needsDisplay = true
            NSSound.beep()
            return
        }
        endEditing()
        onNavigate?(target)
    }

    /// Completes the last path component against the folders that exist.
    private func complete() {
        let text = field.stringValue
        let expanded = text.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + text.dropFirst() : text
        let dir: String, prefix: String
        if expanded.hasSuffix("/") {
            dir = expanded; prefix = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        let base = dir.hasPrefix("/") ? dir : (path as NSString).appendingPathComponent(dir)
        let matches = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) && (prefix.hasPrefix(".") || !$0.hasPrefix(".")) }
            .filter { var d: ObjCBool = false
                      return FileManager.default.fileExists(atPath: base + "/" + $0, isDirectory: &d) && d.boolValue }
            .sorted()
        guard let first = matches.first else { NSSound.beep(); return }
        var common = first
        for m in matches.dropFirst() {
            while !m.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
        }
        let head = text.hasSuffix("/") ? text : String(text.dropLast(prefix.count))
        field.stringValue = head + common + (matches.count == 1 ? "/" : "")
        invalid = false
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.insertTab(_:)): complete(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(); onCancel?(); return true
        default: return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if invalid { invalid = false; needsDisplay = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if isEditing { endEditing() }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = segments.firstIndex { $0.rect.contains(p) }
        if h != hovered { hovered = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func resetCursorRects() {
        for s in segments { addCursorRect(s.rect, cursor: .pointingHand) }
        addCursorRect(editButtonRect, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditing else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let s = segments.first(where: { $0.rect.contains(p) }) {
            if s.path != path { onNavigate?(s.path) }
            return
        }
        beginEditing()
    }

    // MARK: Drawing

    private func crumbs() -> [(title: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out: [(String, String)] = []
        var rest: [String]
        if path == home || path.hasPrefix(home + "/") {
            out.append(("~", home))
            rest = path.dropFirst(home.count).split(separator: "/").map(String.init)
            var acc = home
            for c in rest { acc += "/" + c; out.append((c, acc)) }
        } else {
            out.append(("/", "/"))
            rest = path.split(separator: "/").map(String.init)
            var acc = ""
            for c in rest { acc += "/" + c; out.append((c, acc)) }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, m = margin
        let midY = bounds.height / 2

        // Hairline below, like the rule under a dateline.
        theme.ink.withAlphaComponent(0.18).setFill()
        NSRect(x: m, y: bounds.height - 0.5, width: w - m * 2, height: 0.5).fill()

        // Right-hand affordance.
        let hintFont = theme.smallCapsFont(9)
        let hint = NSAttributedString(string: isEditing ? "RETURN · ESC · TAB" : "GO TO…  ⌘L",
                                      attributes: [.font: hintFont, .foregroundColor: theme.muted, .kern: 1.3])
        let hs = hint.size()
        editButtonRect = NSRect(x: w - m - hs.width - 4, y: 0, width: hs.width + 8, height: bounds.height)
        hint.draw(at: NSPoint(x: w - m - hs.width, y: midY - hs.height / 2))

        if isEditing {
            (invalid ? theme.accent : theme.ink).setFill()
            NSRect(x: m, y: bounds.height - 4, width: w - m * 2 - hs.width - 16, height: invalid ? 1.5 : 1).fill()
            segments = []
            window?.invalidateCursorRects(for: self)
            return
        }

        let font = theme.headline == .grotesk
            ? NSFont.systemFont(ofSize: 11.5, weight: .medium)
            : Theme.serif(12, weight: .regular)
        let bold = theme.headline == .grotesk
            ? NSFont.systemFont(ofSize: 11.5, weight: .bold)
            : Theme.serif(12, weight: .semibold)
        let sep = NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: theme.muted])
        let sepW = sep.size().width

        var items = crumbs()
        let available = w - m * 2 - hs.width - 24
        func width(_ list: [(title: String, path: String)]) -> CGFloat {
            list.enumerated().reduce(0) { acc, e in
                acc + NSAttributedString(string: e.element.title, attributes: [.font: e.offset == list.count - 1 ? bold : font])
                    .size().width + (e.offset > 0 ? sepW : 0)
            }
        }
        // Collapse from the left, keeping the root, until it fits.
        var collapsed = false
        while items.count > 2 && width(items) + (collapsed ? sepW + 12 : 0) > available {
            items.remove(at: 1); collapsed = true
        }

        var x = m
        var newSegments: [(NSRect, String)] = []
        for (i, item) in items.enumerated() {
            if i > 0 {
                sep.draw(at: NSPoint(x: x, y: midY - sep.size().height / 2)); x += sepW
                if i == 1 && collapsed {
                    let dots = NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: theme.muted])
                    dots.draw(at: NSPoint(x: x, y: midY - dots.size().height / 2))
                    x += dots.size().width
                    sep.draw(at: NSPoint(x: x, y: midY - sep.size().height / 2)); x += sepW
                }
            }
            let last = i == items.count - 1
            let isHover = hovered == newSegments.count
            let color = last ? theme.ink : (isHover ? theme.accent : theme.ink.withAlphaComponent(0.72))
            let str = NSAttributedString(string: item.title, attributes: [
                .font: last ? bold : font, .foregroundColor: color,
                .underlineStyle: isHover && !last ? NSUnderlineStyle.single.rawValue : 0,
            ])
            let size = str.size()
            str.draw(at: NSPoint(x: x, y: midY - size.height / 2))
            newSegments.append((NSRect(x: x - 3, y: 0, width: size.width + 6, height: bounds.height), item.path))
            x += size.width
        }
        let changed = newSegments.map(\.1) != segments.map(\.path)
            || newSegments.map(\.0) != segments.map(\.rect)
        segments = newSegments.map { (rect: $0.0, path: $0.1) }
        if changed { window?.invalidateCursorRects(for: self) }
    }
}

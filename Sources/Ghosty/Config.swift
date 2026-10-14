import AppKit

/// Ghostty-style `key = value` configuration at ~/.config/ghosty/config.
final class Config {
    static let shared = Config()
    static let didChange = Notification.Name("GhostyConfigDidChange")

    private(set) var fontFamily: String?
    private(set) var fontSize: CGFloat = 13
    private(set) var theme = "auto"
    private(set) var lineHeight: CGFloat = 1.25
    private(set) var optionAsAlt = false
    private(set) var scrollbackLimit = 10_000
    private(set) var paddingX: CGFloat = 30
    private(set) var paddingY: CGFloat = 10
    private(set) var cursorStyle: CursorShape = .block
    private(set) var columns = 100
    private(set) var rows = 30
    private(set) var copyOnSelect = false
    private(set) var editionName = "The Ghosty Gazette"

    var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghosty/config")
    }

    static let template = """
    # Ghosty — configuration
    # Lines are `key = value`. Reload with ⇧⌘, after editing.

    # theme = auto | broadsheet | night | wired | <light>:<dark>
    theme = auto

    # The nameplate printed above every page.
    edition-name = The Ghosty Gazette

    # font-family = JetBrains Mono     (defaults to SF Mono)
    font-size = 13
    line-height = 1.25

    cursor-style = block              # block | bar | underline
    macos-option-as-alt = false
    copy-on-select = false
    scrollback-limit = 10000

    window-padding-x = 30
    window-padding-y = 10
    window-width = 100                # columns
    window-height = 30                # rows

    """

    func load() {
        fontFamily = nil; fontSize = 13; theme = "auto"; lineHeight = 1.25
        optionAsAlt = false; scrollbackLimit = 10_000; paddingX = 30; paddingY = 10
        cursorStyle = .block; columns = 100; rows = 30; copyOnSelect = false
        editionName = "The Ghosty Gazette"

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            apply(key, value)
        }
    }

    private func apply(_ key: String, _ value: String) {
        let num = Double(value).map { CGFloat($0) }
        let bool = ["true", "yes", "on", "1", "left", "right"].contains(value.lowercased())
        switch key {
        case "font-family": fontFamily = value.isEmpty ? nil : value
        case "font-size": if let n = num, n >= 6, n <= 72 { fontSize = n }
        case "theme": theme = value
        case "line-height", "adjust-cell-height": if let n = num, n >= 0.8, n <= 3 { lineHeight = n }
        case "macos-option-as-alt": optionAsAlt = bool
        case "scrollback-limit": if let n = Int(value), n >= 0 { scrollbackLimit = n }
        case "window-padding-x": if let n = num, n >= 0 { paddingX = n }
        case "window-padding-y": if let n = num, n >= 0 { paddingY = n }
        case "window-width": if let n = Int(value), n >= 20 { columns = n }
        case "window-height": if let n = Int(value), n >= 5 { rows = n }
        case "copy-on-select": copyOnSelect = bool
        case "edition-name": editionName = value
        case "cursor-style":
            switch value.lowercased() {
            case "bar": cursorStyle = .bar
            case "underline": cursorStyle = .underline
            default: cursorStyle = .block
            }
        default: break
        }
    }

    func ensureFile() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Config.template.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rewrite (or append) a single key in the config file, then reload.
    func update(_ key: String, _ value: String) {
        ensureFile()
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
        var found = false
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            if t[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == key {
                lines[i] = "\(key) = \(value)"
                found = true
            }
        }
        if !found { lines.append("\(key) = \(value)") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    func reload() {
        load()
        NotificationCenter.default.post(name: Config.didChange, object: self)
    }
}

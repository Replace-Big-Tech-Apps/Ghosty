import AppKit

/// Folders recently visited in any Ghosty tab, most recent first.
enum RecentDirectories {
    private static let key = "recentDirectories"
    private static let limit = 12

    static var all: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func add(_ path: String) {
        guard path != FileManager.default.homeDirectoryForCurrentUser.path, path != "/" else { return }
        var list = all.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func icon(for path: String) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    /// Quick destinations that exist on this Mac.
    static var places: [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return [home, home + "/Desktop", home + "/Documents", home + "/Downloads"]
            .filter { fm.fileExists(atPath: $0) }
    }
}

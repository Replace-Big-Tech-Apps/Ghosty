import AppKit

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: alpha)
    }

    var rgb8: (UInt8, UInt8, UInt8) {
        let c = usingColorSpace(.sRGB) ?? self
        return (UInt8(clamping: Int(round(c.redComponent * 255))),
                UInt8(clamping: Int(round(c.greenComponent * 255))),
                UInt8(clamping: Int(round(c.blueComponent * 255))))
    }
}

/// An "edition": paper, ink and type for the whole window.
struct Theme {
    enum HeadlineStyle { case serif, grotesk }

    let id: String
    let name: String
    let isDark: Bool
    let paper: NSColor
    let ink: NSColor
    let accent: NSColor
    let muted: NSColor
    let highlighter: NSColor
    let highlighterMultiply: Bool
    let grain: CGFloat
    let headline: HeadlineStyle
    let ansi: [NSColor]

    // MARK: Type

    func headlineFont(_ size: CGFloat) -> NSFont {
        switch headline {
        case .serif:
            return Theme.serif(size, weight: .bold)
        case .grotesk:
            return NSFont.systemFont(ofSize: size, weight: .black, width: .condensed)
        }
    }

    func kickerFont(_ size: CGFloat) -> NSFont {
        headline == .grotesk
            ? NSFont.systemFont(ofSize: size, weight: .heavy, width: .condensed)
            : NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    func dekFont(_ size: CGFloat) -> NSFont {
        headline == .grotesk
            ? NSFont.systemFont(ofSize: size, weight: .regular)
            : Theme.serif(size, weight: .regular, italic: true)
    }

    func smallCapsFont(_ size: CGFloat) -> NSFont {
        headline == .grotesk
            ? NSFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
            : Theme.serif(size, weight: .medium)
    }

    static func serif(_ size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic { desc = desc.withSymbolicTraits(.italic) }
        return NSFont(descriptor: desc, size: size) ?? NSFont(name: "Times New Roman", size: size) ?? base
    }

    // MARK: Editions

    static let broadsheet = Theme(
        id: "broadsheet", name: "Broadsheet", isDark: false,
        paper: NSColor(hex: "#FBFBFA"), ink: NSColor(hex: "#18181A"),
        accent: NSColor(hex: "#D3261D"), muted: NSColor(hex: "#85858A"),
        highlighter: NSColor(hex: "#F6D54A", alpha: 0.72), highlighterMultiply: true,
        grain: 0.6, headline: .serif,
        ansi: ["#18181A", "#B0281F", "#3D6B2E", "#94650A", "#24508A", "#883A6E", "#1D6A6E", "#7A7A7F",
               "#58585D", "#D3261D", "#4E8A3B", "#B07C12", "#2F68B0", "#A8508A", "#278489", "#36363A"]
            .map { NSColor(hex: $0) })

    static let night = Theme(
        id: "night", name: "Night Edition", isDark: true,
        paper: NSColor(hex: "#16150F"), ink: NSColor(hex: "#E6E0CF"),
        accent: NSColor(hex: "#FF5A47"), muted: NSColor(hex: "#8F887A"),
        highlighter: NSColor(hex: "#C9A227", alpha: 0.38), highlighterMultiply: false,
        grain: 0.8, headline: .serif,
        ansi: ["#2A2822", "#E0604F", "#8DB570", "#D9AE4F", "#7EA2D6", "#C98AB8", "#6DB7B3", "#CFC8B6",
               "#5F5A4E", "#FF7A66", "#A8D18A", "#F0C866", "#9DBDF0", "#E2A6D1", "#8AD3CE", "#F4EFE2"]
            .map { NSColor(hex: $0) })

    static let wired = Theme(
        id: "wired", name: "Wired", isDark: false,
        paper: NSColor(hex: "#FAFAF7"), ink: NSColor(hex: "#0B0B0B"),
        accent: NSColor(hex: "#FF3D00"), muted: NSColor(hex: "#767676"),
        highlighter: NSColor(hex: "#E6FF00", alpha: 0.85), highlighterMultiply: true,
        grain: 0.35, headline: .grotesk,
        ansi: ["#0B0B0B", "#E8261C", "#00873E", "#B58900", "#0047FF", "#C2008F", "#00838F", "#6E6E6E",
               "#4A4A4A", "#FF3D00", "#00A651", "#D9A400", "#2F6BFF", "#E0219E", "#00A3B2", "#262626"]
            .map { NSColor(hex: $0) })

    static let all: [Theme] = [broadsheet, night, wired]

    /// Resolve a config value ("auto", "broadsheet", "night", "wired", or "light:dark" pair).
    static func resolve(_ name: String, appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if key.contains(":") {
            let pair = key.split(separator: ":").map(String.init)
            return named(dark ? pair.last! : pair.first!) ?? (dark ? night : broadsheet)
        }
        if key == "auto" || key.isEmpty { return dark ? night : broadsheet }
        return named(key) ?? broadsheet
    }

    static func named(_ key: String) -> Theme? {
        switch key {
        case "broadsheet", "paper", "light": return broadsheet
        case "night", "night-edition", "dark": return night
        case "wired": return wired
        default: return nil
        }
    }
}

// MARK: - Paper grain

enum PaperTexture {
    private static var cache: [String: NSImage] = [:]

    /// A tileable speckle texture that reads as uncoated newsprint.
    static func grain(for theme: Theme) -> NSImage {
        if let img = cache[theme.id] { return img }
        let size = 220
        var px = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt32 = 0x9E3779B9
        func rnd() -> UInt32 {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return seed
        }
        let tone: UInt8 = theme.isDark ? 255 : 40
        let strength = Double(theme.grain)
        for i in 0..<(size * size) {
            let n = Double(rnd() % 10_000) / 10_000
            var a = pow(n, 6) * 34 * strength
            // Occasional darker fleck, like pulp in cheap paper.
            if rnd() % 2400 == 0 { a = 70 * strength }
            px[i * 4 + 0] = tone
            px[i * 4 + 1] = tone
            px[i * 4 + 2] = tone
            px[i * 4 + 3] = UInt8(min(255, a))
        }
        // Premultiply.
        for i in 0..<(size * size) {
            let a = UInt16(px[i * 4 + 3])
            for c in 0..<3 { px[i * 4 + c] = UInt8(UInt16(px[i * 4 + c]) * a / 255) }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let img = NSImage(cgImage: cg, size: NSSize(width: size / 2, height: size / 2))
        cache[theme.id] = img
        return img
    }
}

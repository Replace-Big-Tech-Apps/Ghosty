import AppKit

private func tracked(_ s: String, font: NSFont, color: NSColor, kern: CGFloat) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
}

private func truncating(_ s: String, font: NSFont, color: NSColor, kern: CGFloat = 0,
                        align: NSTextAlignment = .left, head: Bool = false) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = head ? .byTruncatingHead : .byTruncatingTail
    p.alignment = align
    return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color,
                                                      .kern: kern, .paragraphStyle: p])
}

/// The sheet of paper everything sits on: flat stock, grain, and a faint vignette.
final class PageView: NSView {
    var theme: Theme = .broadsheet { didSet { needsDisplay = true } }
    let masthead = MastheadView()
    let pathBar = PathBar()
    let footer = FooterView()
    let content: NSView

    static let mastheadHeight: CGFloat = 92
    static let footerHeight: CGFloat = 30
    static let pathBarHeight: CGFloat = 28
    static var chromeHeight: CGFloat { mastheadHeight + pathBarHeight + footerHeight }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(masthead)
        addSubview(pathBar)
        addSubview(content)
        addSubview(footer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Extra space taken by the native tab bar, which sits over our full-size content.
    private var tabBarInset: CGFloat {
        guard let window, window.styleMask.contains(.fullSizeContentView) else { return 0 }
        let covered = bounds.height - window.contentLayoutRect.height
        guard window.tabGroup?.isTabBarVisible == true else { return 0 }
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let titlebar = NSWindow.frameRect(forContentRect: probe, styleMask: [.titled]).height - probe.height
        return max(0, covered - titlebar)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let top = tabBarInset
        masthead.bodyOffset = top
        masthead.frame = CGRect(x: 0, y: 0, width: w, height: top + PageView.mastheadHeight)
        footer.frame = CGRect(x: 0, y: h - PageView.footerHeight, width: w, height: PageView.footerHeight)
        let barY = top + PageView.mastheadHeight
        pathBar.frame = CGRect(x: 0, y: barY, width: w, height: PageView.pathBarHeight)
        content.frame = CGRect(x: 0, y: barY + PageView.pathBarHeight, width: w,
                               height: max(0, h - top - PageView.chromeHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.paper.setFill()
        bounds.fill()
        NSColor(patternImage: PaperTexture.grain(for: theme)).setFill()
        bounds.fill()

        // Edges of a page catch a little more shadow than the middle.
        let edge = theme.isDark ? NSColor.black.withAlphaComponent(0.35)
                                : NSColor(white: 0.2, alpha: 0.06)
        if let g = NSGradient(colors: [edge.withAlphaComponent(0), edge]) {
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = hypot(bounds.width, bounds.height) / 2
            g.draw(fromCenter: c, radius: radius * 0.55, toCenter: c, radius: radius, options: [])
        }
    }
}

/// Nameplate, kicker, headline and dek — the top of a newspaper page.
final class MastheadView: NSView {
    var theme: Theme = .broadsheet { didSet { needsDisplay = true } }
    var edition = "The Ghosty Gazette" { didSet { needsDisplay = true } }
    var kicker = "" { didSet { if kicker != oldValue { needsDisplay = true } } }
    var kickerIsLive = false { didSet { if kickerIsLive != oldValue { needsDisplay = true } } }
    var headline = "" { didSet { if headline != oldValue { needsDisplay = true } } }
    var dek = "" { didSet { if dek != oldValue { needsDisplay = true } } }
    var margin: CGFloat = 30 { didSet { needsDisplay = true } }
    /// Kicker, headline and rules drop below the tab bar; the nameplate band stays in the titlebar.
    var bodyOffset: CGFloat = 0 { didSet { if bodyOffset != oldValue { needsDisplay = true } } }

    /// Called when the headline (the current directory) is clicked; receives the headline's rect.
    var onHeadlineClick: ((NSRect) -> Void)?
    private var headlineHitRect = NSRect.zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        if !headlineHitRect.isEmpty { addCursorRect(headlineHitRect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if headlineHitRect.contains(p), let onHeadlineClick {
            onHeadlineClick(headlineHitRect)
            return
        }
        if event.clickCount == 2 { window?.performZoom(nil); return }
        window?.performDrag(with: event)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let m = margin
        let ink = theme.ink, muted = theme.muted, accent = theme.accent
        let grotesk = theme.headline == .grotesk

        // ── Top band (shares the titlebar): date · NAMEPLATE · edition note
        let bandY: CGFloat = 9
        let leftEdge = max(m, 84)   // clear the traffic lights
        let small = theme.smallCapsFont(9)
        let date = tracked(MastheadView.dateFormatter.string(from: Date()).uppercased(),
                           font: small, color: muted, kern: 1.4)
        let note = tracked(grotesk ? "SIGNAL · NOISE · SHELL" : "LATE CITY EDITION",
                           font: small, color: muted, kern: 1.4)
        let plateFont = grotesk ? NSFont.systemFont(ofSize: 13, weight: .black, width: .condensed)
                                : Theme.serif(14, weight: .heavy)
        let plate = tracked(grotesk ? edition.uppercased() : edition, font: plateFont, color: ink,
                            kern: grotesk ? 2.5 : 0.6)
        let plateSize = plate.size()
        let plateX = round((w - plateSize.width) / 2)
        plate.draw(at: NSPoint(x: plateX, y: bandY - 2))
        let midY = bandY + 6.5
        let dateSize = date.size(), noteSize = note.size()
        if leftEdge + dateSize.width + 24 < plateX {
            date.draw(at: NSPoint(x: leftEdge, y: bandY + 1))
        }
        if plateX + plateSize.width + 24 + noteSize.width < w - m {
            note.draw(at: NSPoint(x: w - m - noteSize.width, y: bandY + 1))
        }
        // Hairlines flanking the nameplate.
        ink.withAlphaComponent(0.35).setFill()
        let l0 = leftEdge + dateSize.width + 12, l1 = plateX - 12
        if l1 > l0 { NSRect(x: l0, y: midY, width: l1 - l0, height: 0.5).fill() }
        let r0 = plateX + plateSize.width + 12, r1 = w - m - noteSize.width - 12
        if r1 > r0 { NSRect(x: r0, y: midY, width: r1 - r0, height: 0.5).fill() }

        // ── Kicker
        let kickerY: CGFloat = 32 + bodyOffset
        let kickerColor = kickerIsLive ? accent : muted
        let k = tracked(kicker.uppercased(), font: theme.kickerFont(9.5), color: kickerColor, kern: 1.6)
        if kickerIsLive {
            accent.setFill()
            NSRect(x: m, y: kickerY + 3.5, width: 6, height: 6).fill()
            k.draw(at: NSPoint(x: m + 11, y: kickerY))
        } else {
            k.draw(at: NSPoint(x: m, y: kickerY))
        }

        // ── Headline and dek on a shared line
        let headY: CGFloat = 45 + bodyOffset
        let dekFont = theme.dekFont(12.5)
        // Paths lose their beginning, not their end.
        let dekStr = truncating(dek, font: dekFont, color: muted, align: .right, head: dek.hasPrefix("in "))
        let dekWidth = min(dekStr.size().width + 2, w * 0.45)
        let headFont = theme.headlineFont(grotesk ? 27 : 25)
        let headText = grotesk ? headline.uppercased() : headline
        let head = truncating(headText, font: headFont, color: ink, kern: grotesk ? 0.2 : -0.3)
        let headRect = NSRect(x: m, y: headY, width: max(40, w - m * 2 - dekWidth - 24), height: 34)
        head.draw(with: headRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // A small caret marks the headline as a folder picker.
        let headWidth = min(head.size().width, headRect.width)
        let caret = tracked("▾", font: NSFont.systemFont(ofSize: grotesk ? 13 : 12, weight: .semibold),
                            color: muted, kern: 0)
        let caretX = headRect.minX + headWidth + 6
        caret.draw(at: NSPoint(x: caretX, y: headY + (grotesk ? 11 : 10)))
        let hit = NSRect(x: headRect.minX - 4, y: headY - 2, width: caretX + 16 - headRect.minX + 4, height: 36)
        if hit != headlineHitRect {
            headlineHitRect = hit
            window?.invalidateCursorRects(for: self)
        }
        let dekRect = NSRect(x: w - m - dekWidth, y: headY + (grotesk ? 12 : 10), width: dekWidth, height: 18)
        dekStr.draw(with: dekRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // ── Rules: thick + thin (Wired gets a solid accent bar)
        let ruleY = bounds.height - 9
        if grotesk {
            ink.setFill()
            NSRect(x: m, y: ruleY, width: w - m * 2, height: 4).fill()
            accent.setFill()
            NSRect(x: m, y: ruleY, width: min(96, w - m * 2), height: 4).fill()
        } else {
            ink.setFill()
            NSRect(x: m, y: ruleY, width: w - m * 2, height: 2.5).fill()
            NSRect(x: m, y: ruleY + 4.5, width: w - m * 2, height: 0.75).fill()
        }
    }
}

/// Folio line at the foot of the page.
final class FooterView: NSView {
    var theme: Theme = .broadsheet { didSet { needsDisplay = true } }
    var left = "" { didSet { if left != oldValue { needsDisplay = true } } }
    var center = "" { didSet { if center != oldValue { needsDisplay = true } } }
    var right = "" { didSet { if right != oldValue { needsDisplay = true } } }
    var rightIsAlert = false { didSet { if rightIsAlert != oldValue { needsDisplay = true } } }
    var margin: CGFloat = 30 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, m = margin
        theme.ink.withAlphaComponent(0.55).setFill()
        NSRect(x: m, y: 4, width: w - m * 2, height: 0.5).fill()

        let f = theme.smallCapsFont(9)
        let y: CGFloat = 11
        let third = (w - m * 2) / 3
        truncating(left.uppercased(), font: f, color: theme.muted, kern: 1.3)
            .draw(with: NSRect(x: m, y: y, width: third, height: 14), options: [.usesLineFragmentOrigin])
        let folio = theme.headline == .grotesk ? theme.kickerFont(10) : Theme.serif(10.5, weight: .regular, italic: true)
        truncating(center, font: folio, color: theme.ink, align: .center)
            .draw(with: NSRect(x: m + third, y: y - 1, width: third, height: 14), options: [.usesLineFragmentOrigin])
        truncating(right.uppercased(), font: f, color: rightIsAlert ? theme.accent : theme.muted,
                   kern: 1.3, align: .right)
            .draw(with: NSRect(x: m + third * 2, y: y, width: third, height: 14), options: [.usesLineFragmentOrigin])
    }
}

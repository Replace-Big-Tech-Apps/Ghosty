import AppKit
import CoreText

protocol TerminalViewDelegate: AnyObject {
    func terminalViewStateDidChange(_ view: TerminalView)
    func terminalViewProcessDidExit(_ view: TerminalView)
}

private struct GridPoint: Comparable {
    var row: Int   // absolute row (stable across scrollback trimming)
    var col: Int
    static func < (a: GridPoint, b: GridPoint) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }
}

private enum SelectionMode { case char, word, line }

/// Renders a `Terminal` with Core Text and turns AppKit input into bytes for the PTY.
final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation, TerminalDelegate {
    weak var delegate: TerminalViewDelegate?
    let terminal: Terminal
    private(set) var pty: PTY?

    var theme: Theme { didSet { rebuildColors(); needsDisplay = true } }
    private(set) var fontSize: CGFloat
    private var fontRegular: CTFont!
    private var fontBold: CTFont!
    private var fontItalic: CTFont!
    private var fontBoldItalic: CTFont!
    private(set) var cellWidth: CGFloat = 8
    private(set) var cellHeight: CGFloat = 16
    private var baseline: CGFloat = 12
    private var lineWidthLight: CGFloat = 1

    var padX: CGFloat { Config.shared.paddingX }
    var padY: CGFloat { Config.shared.paddingY }

    /// Lines scrolled back from the live screen (0 = following output).
    private(set) var scrollOffset = 0
    private var scrollRemainder: CGFloat = 0

    private var palette: [CGColor] = []
    private var inkColor: CGColor = .black
    private var paperColor: CGColor = .white
    private var accentColor: CGColor = .black
    private var rgbCache: [UInt32: CGColor] = [:]

    private var selAnchor: GridPoint?
    private var selHead: GridPoint?
    private var selMode: SelectionMode = .char
    private var mouseIsSelecting = false
    private var lastMouseButton = 0

    private var markedText = ""
    private var focused = false
    private var flashLayer: CALayer?

    init(frame: NSRect, theme: Theme) {
        self.theme = theme
        fontSize = Config.shared.fontSize
        terminal = Terminal(cols: Config.shared.columns, rows: Config.shared.rows)
        super.init(frame: frame)
        terminal.delegate = self
        terminal.scrollbackLimit = Config.shared.scrollbackLimit
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
        configureFonts()
        rebuildColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    func start(cwd: String?) {
        guard pty == nil else { return }
        updateGrid()
        do {
            let p = try PTY(cols: terminal.cols, rows: terminal.rows, cwd: cwd)
            p.onData = { [weak self] data in self?.receive(data) }
            p.onExit = { [weak self] in
                guard let self else { return }
                self.delegate?.terminalViewProcessDidExit(self)
            }
            pty = p
            p.resize(cols: terminal.cols, rows: terminal.rows, width: bounds.width, height: bounds.height)
        } catch {
            terminal.feed("\r\n  Ghosty could not start a shell: \(error.localizedDescription)\r\n")
        }
    }

    func shutdown() {
        pty?.onExit = nil
        pty?.terminate()
    }

    private func receive(_ data: UnsafeRawBufferPointer) {
        terminal.feed(data)
        let pushed = terminal.takePushedLines()
        if scrollOffset > 0 && pushed > 0 {
            scrollOffset = min(scrollOffset + pushed, terminal.scrollback.count)
        }
        needsDisplay = true
    }

    func applyConfig() {
        terminal.scrollbackLimit = Config.shared.scrollbackLimit
        fontSize = Config.shared.fontSize
        configureFonts()
        updateGrid()
        needsDisplay = true
    }

    // MARK: Fonts & colours

    private func configureFonts() {
        let size = fontSize
        var base: NSFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var bold: NSFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        if let family = Config.shared.fontFamily,
           let f = NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            base = f
            bold = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        }
        func italic(_ f: NSFont) -> NSFont {
            NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(
                f.fontDescriptor.symbolicTraits.union(.italic)), size: size) ?? f
        }
        fontRegular = base as CTFont
        fontBold = bold as CTFont
        fontItalic = italic(base) as CTFont
        fontBoldItalic = italic(bold) as CTFont

        var glyph = CGGlyph(0)
        var ch: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(fontRegular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(fontRegular, .horizontal, &glyph, &advance, 1)
        cellWidth = max(1, advance.width)

        let ascent = CTFontGetAscent(fontRegular)
        let descent = CTFontGetDescent(fontRegular)
        let leading = CTFontGetLeading(fontRegular)
        let natural = ceil(ascent + descent + leading)
        cellHeight = ceil(natural * Config.shared.lineHeight)
        baseline = round((cellHeight - (ascent + descent)) / 2 + ascent)
        lineWidthLight = max(1, round(size / 13))
    }

    private func rebuildColors() {
        rgbCache.removeAll()
        var p = theme.ansi.map { $0.usingColorSpace(.sRGB)!.cgColor }
        func comp(_ v: Int) -> CGFloat { v == 0 ? 0 : CGFloat(55 + v * 40) / 255 }
        for i in 16..<256 {
            if i < 232 {
                let n = i - 16
                p.append(CGColor(srgbRed: comp(n / 36), green: comp((n / 6) % 6), blue: comp(n % 6), alpha: 1))
            } else {
                let g = CGFloat(8 + (i - 232) * 10) / 255
                p.append(CGColor(srgbRed: g, green: g, blue: g, alpha: 1))
            }
        }
        palette = p
        inkColor = theme.ink.cgColor
        paperColor = theme.paper.cgColor
        accentColor = theme.accent.cgColor
    }

    @inline(__always) private func color(_ c: TermColor) -> CGColor? {
        switch c {
        case .default: return nil
        case .indexed(let i): return palette[Int(i)]
        case .rgb(let r, let g, let b):
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            if let c = rgbCache[key] { return c }
            let c = CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            if rgbCache.count > 4096 { rgbCache.removeAll() }
            rgbCache[key] = c
            return c
        }
    }

    /// Effective (foreground, background) for a cell; background nil means "paper".
    @inline(__always) private func resolve(_ a: Attr) -> (CGColor, CGColor?) {
        var fg = color(a.fg) ?? inkColor
        var bg = color(a.bg)
        if a.has(Attr.inverse) != terminal.reverseVideo {
            let f = fg
            fg = bg ?? paperColor
            bg = f
        }
        if a.has(Attr.dim) { fg = fg.copy(alpha: 0.55) ?? fg }
        if a.has(Attr.hidden) { fg = bg ?? paperColor }
        return (fg, bg)
    }

    @inline(__always) private func font(for a: Attr) -> CTFont {
        switch (a.has(Attr.bold), a.has(Attr.italic)) {
        case (true, true): return fontBoldItalic
        case (true, false): return fontBold
        case (false, true): return fontItalic
        default: return fontRegular
        }
    }

    // MARK: Geometry

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    private func updateGrid() {
        let c = max(10, Int((bounds.width - padX * 2) / cellWidth))
        let r = max(3, Int((bounds.height - padY * 2) / cellHeight))
        if c != terminal.cols || r != terminal.rows {
            terminal.resize(cols: c, rows: r)
            pty?.resize(cols: c, rows: r, width: bounds.width, height: bounds.height)
            scrollOffset = min(scrollOffset, terminal.scrollback.count)
            delegate?.terminalViewStateDidChange(self)
        }
        needsDisplay = true
    }

    /// Content size needed to show `cols` × `rows` cells.
    func sizeFor(cols: Int, rows: Int) -> NSSize {
        NSSize(width: ceil(CGFloat(cols) * cellWidth + padX * 2),
               height: ceil(CGFloat(rows) * cellHeight + padY * 2))
    }

    /// Round to the device pixel grid so adjacent cell backgrounds never show seams.
    @inline(__always) private func snap(_ v: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return round(v * scale) / scale
    }

    private var topCombinedIndex: Int { terminal.scrollback.count - scrollOffset }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldAntialias(true)

        let cols = terminal.cols
        let top = topCombinedIndex
        let sel = selectionRange()
        let cursorShape = terminal.cursorShape ?? Config.shared.cursorStyle
        let showCursor = scrollOffset == 0 && terminal.cursorVisible && markedText.isEmpty
        let cursorRow = terminal.cursorY

        for r in 0..<terminal.rows {
            let y = padY + CGFloat(r) * cellHeight
            if y > dirtyRect.maxY || y + cellHeight < dirtyRect.minY { continue }
            guard let line = terminal.line(atCombined: top + r) else { continue }
            let absRow = terminal.droppedLines + top + r
            let n = min(cols, line.cells.count)

            // 1. Cell backgrounds, merged into runs.
            var runColor: CGColor?
            var runStart = 0
            func flushBG(_ end: Int) {
                guard let c = runColor, end > runStart else { return }
                ctx.setFillColor(c)
                let x0 = snap(padX + CGFloat(runStart) * cellWidth)
                let x1 = snap(padX + CGFloat(end) * cellWidth)
                ctx.fill(CGRect(x: x0, y: y, width: x1 - x0, height: cellHeight))
            }
            for x in 0..<n {
                let bg = resolve(line.cells[x].attr).1
                if bg !== runColor {
                    flushBG(x)
                    runColor = bg
                    runStart = x
                }
            }
            flushBG(n)

            // 2. Highlighter-pen selection.
            if let (s, e) = sel, absRow >= s.row, absRow <= e.row {
                let c0 = absRow == s.row ? s.col : 0
                let c1 = absRow == e.row ? e.col : cols
                if c1 > c0 {
                    ctx.saveGState()
                    if theme.highlighterMultiply { ctx.setBlendMode(.multiply) }
                    ctx.setFillColor(theme.highlighter.cgColor)
                    let rect = CGRect(x: padX + CGFloat(c0) * cellWidth, y: y + 1,
                                      width: CGFloat(c1 - c0) * cellWidth, height: cellHeight - 2)
                    ctx.fill(rect)
                    ctx.restoreGState()
                }
            }

            // 3. Block cursor sits under the glyph.
            var cursorCol: Int? = nil
            if showCursor && r == cursorRow && focused && cursorShape == .block {
                let cx = min(terminal.cursorX, cols - 1)
                let wide = cx < n && line.cells[cx].width == 2
                ctx.setFillColor(accentColor)
                ctx.fill(CGRect(x: padX + CGFloat(cx) * cellWidth, y: y,
                                width: cellWidth * (wide ? 2 : 1), height: cellHeight))
                cursorCol = cx
            }

            // 4. Glyphs.
            drawText(line: line, count: n, y: y, cursorCol: cursorCol, ctx: ctx)
        }

        if showCursor && !(focused && cursorShape == .block) {
            drawCursorOutline(shape: cursorShape, ctx: ctx)
        }
        if !markedText.isEmpty { drawMarkedText(ctx: ctx) }
    }

    private func drawText(line: Line, count n: Int, y: CGFloat, cursorCol: Int?, ctx: CGContext) {
        var run = ""
        var runStart = 0
        var runFont: CTFont = fontRegular
        var runColor: CGColor = inkColor
        var runFlags: UInt16 = 0

        func flush() {
            guard !run.isEmpty else { return }
            drawString(run, x: padX + CGFloat(runStart) * cellWidth, y: y, font: runFont, color: runColor, ctx: ctx)
            decorate(flags: runFlags, x: padX + CGFloat(runStart) * cellWidth, y: y,
                     width: CGFloat(run.count) * cellWidth, color: runColor, ctx: ctx)
            run = ""
        }

        for x in 0..<n {
            let cell = line.cells[x]
            if cell.width == 0 { continue }
            var (fg, _) = resolve(cell.attr)
            if x == cursorCol { fg = paperColor }
            let decoFlags = cell.attr.flags & (Attr.underline | Attr.strike | Attr.doubleUnderline)
            let ch = cell.ch

            if ch == " " && decoFlags == 0 {
                if !run.isEmpty && fg === runColor && runFlags == 0 { run.append(" ") } else { flush() }
                continue
            }
            let v = ch.unicodeScalars.first!.value
            if BoxDrawing.handles(v) {
                flush()
                BoxDrawing.draw(v, rect: CGRect(x: padX + CGFloat(x) * cellWidth, y: y,
                                                width: cellWidth, height: cellHeight),
                                color: fg, light: lineWidthLight, ctx: ctx)
                continue
            }
            let f = font(for: cell.attr)
            if !ch.isASCII {
                flush()
                let px = padX + CGFloat(x) * cellWidth
                drawString(String(ch), x: px, y: y, font: f, color: fg, ctx: ctx,
                           maxWidth: cellWidth * CGFloat(max(1, cell.width)))
                decorate(flags: decoFlags, x: px, y: y, width: cellWidth * CGFloat(max(1, cell.width)),
                         color: fg, ctx: ctx)
                continue
            }
            if !run.isEmpty && (f !== runFont || fg !== runColor || decoFlags != runFlags) { flush() }
            if run.isEmpty {
                runStart = x; runFont = f; runColor = fg; runFlags = decoFlags
            }
            run.append(ch)
        }
        flush()
    }

    private func drawString(_ s: String, x: CGFloat, y: CGFloat, font: CTFont, color: CGColor,
                            ctx: CGContext, maxWidth: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        if let maxWidth {
            // Fallback glyphs (emoji, CJK) can be wider than the grid; squeeze them in.
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if w > maxWidth + 0.5 {
                let scale = maxWidth / w
                ctx.saveGState()
                ctx.translateBy(x: x, y: y + baseline)
                ctx.scaleBy(x: scale, y: scale)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
                return
            }
        }
        ctx.textPosition = CGPoint(x: x, y: y + baseline)
        CTLineDraw(line, ctx)
    }

    private func decorate(flags: UInt16, x: CGFloat, y: CGFloat, width: CGFloat, color: CGColor, ctx: CGContext) {
        guard flags != 0 else { return }
        ctx.setFillColor(color)
        let t = lineWidthLight
        if flags & Attr.underline != 0 {
            let uy = y + baseline + max(2, round(t * 2))
            ctx.fill(CGRect(x: x, y: uy, width: width, height: t))
            if flags & Attr.doubleUnderline != 0 {
                ctx.fill(CGRect(x: x, y: uy + t * 2, width: width, height: t))
            }
        }
        if flags & Attr.strike != 0 {
            let sy = y + baseline - round(CTFontGetXHeight(fontRegular) / 2)
            ctx.fill(CGRect(x: x, y: sy, width: width, height: t))
        }
    }

    private func cursorRect() -> CGRect {
        let cx = min(terminal.cursorX, terminal.cols - 1)
        var w = cellWidth
        if let line = terminal.line(atCombined: topCombinedIndex + terminal.cursorY),
           cx < line.cells.count, line.cells[cx].width == 2 { w *= 2 }
        return CGRect(x: padX + CGFloat(cx) * cellWidth, y: padY + CGFloat(terminal.cursorY) * cellHeight,
                      width: w, height: cellHeight)
    }

    private func drawCursorOutline(shape: CursorShape, ctx: CGContext) {
        let r = cursorRect()
        ctx.setFillColor(accentColor)
        ctx.setStrokeColor(accentColor)
        if !focused {
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            return
        }
        switch shape {
        case .bar: ctx.fill(CGRect(x: r.minX, y: r.minY, width: max(2, lineWidthLight * 2), height: r.height))
        case .underline: ctx.fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2))
        case .block: ctx.fill(r)
        }
    }

    private func drawMarkedText(ctx: CGContext) {
        let r = cursorRect()
        let width = CGFloat(markedText.count) * cellWidth * 1.2
        ctx.setFillColor(paperColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: width, height: r.height))
        drawString(markedText, x: r.minX, y: r.minY, font: fontRegular, color: inkColor, ctx: ctx)
        ctx.setFillColor(accentColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY + baseline + 2, width: width, height: 1))
    }

    // MARK: Bell

    func terminalBell(_ terminal: Terminal) {
        guard let layer else { return }
        let flash = flashLayer ?? {
            let l = CALayer()
            layer.addSublayer(l)
            flashLayer = l
            return l
        }()
        flash.frame = layer.bounds
        flash.backgroundColor = theme.accent.withAlphaComponent(0.10).cgColor
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0
        a.duration = 0.35
        flash.opacity = 0
        flash.add(a, forKey: "flash")
    }

    // MARK: TerminalDelegate

    func terminal(_ terminal: Terminal, send bytes: [UInt8]) { pty?.write(bytes) }

    func terminalTitleDidChange(_ terminal: Terminal) { delegate?.terminalViewStateDidChange(self) }

    func terminal(_ terminal: Terminal, setClipboard text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func terminal(_ terminal: Terminal, colorFor slot: Int) -> (UInt8, UInt8, UInt8)? {
        switch slot {
        case 0..<16: return theme.ansi[slot].rgb8
        case 16..<256:
            let c = palette[slot]
            let comps = c.components ?? [0, 0, 0]
            return (UInt8(comps[0] * 255), UInt8(comps[1] * 255), UInt8(comps[2] * 255))
        case 256: return theme.ink.rgb8
        case 257: return theme.paper.rgb8
        case 258: return theme.accent.rgb8
        default: return nil
        }
    }

    // MARK: Focus

    private func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        if terminal.focusReporting { pty?.write(on ? "\u{1b}[I" : "\u{1b}[O") }
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        setFocused(window?.isKeyWindow ?? true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged() {
        setFocused(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: Keyboard

    private func send(_ s: String) {
        pty?.write(s)
    }

    private func userTyped() {
        if scrollOffset != 0 { scrollOffset = 0; delegate?.terminalViewStateDidChange(self) }
        if selAnchor != nil { clearSelection() }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command {
            switch event.keyCode {
            case 123: userTyped(); send("\u{01}"); return true          // ⌘← start of line
            case 124: userTyped(); send("\u{05}"); return true          // ⌘→ end of line
            case 51: userTyped(); send("\u{15}"); return true           // ⌘⌫ kill line
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)
        let control = mods.contains(.control)

        // Shift+PageUp/Down/Home/End scroll the page locally.
        if shift && !control && !option {
            switch event.keyCode {
            case 116: scrollBy(lines: terminal.rows - 1); return
            case 121: scrollBy(lines: -(terminal.rows - 1)); return
            case 115: scrollBy(lines: terminal.scrollback.count); return
            case 119: scrollBy(lines: -scrollOffset); return
            default: break
            }
        }

        if let seq = specialKey(event, shift: shift, option: option, control: control) {
            userTyped()
            send(seq)
            return
        }

        if control, let chars = event.charactersIgnoringModifiers, let c = chars.unicodeScalars.first,
           let code = controlCode(for: c) {
            userTyped()
            let prefix = option && Config.shared.optionAsAlt ? "\u{1b}" : ""
            send(prefix + String(UnicodeScalar(code)))
            return
        }

        if option && Config.shared.optionAsAlt,
           let chars = event.characters(byApplyingModifiers: shift ? .shift : []), !chars.isEmpty {
            userTyped()
            send("\u{1b}" + chars)
            return
        }

        interpretKeyEvents([event])
    }

    private func controlCode(for c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "a"..."z": return UInt8(c.value - 0x60)
        case "A"..."Z": return UInt8(c.value - 0x40)
        case "@", " ", "2": return 0
        case "[", "3": return 27
        case "\\", "4": return 28
        case "]", "5": return 29
        case "^", "6": return 30
        case "_", "-", "/", "7": return 31
        case "8", "?": return 127
        default: return nil
        }
    }

    private func specialKey(_ e: NSEvent, shift: Bool, option: Bool, control: Bool) -> String? {
        let mod = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        let app = terminal.applicationCursorKeys
        func cursor(_ c: String) -> String {
            if mod > 1 { return "\u{1b}[1;\(mod)\(c)" }
            return app ? "\u{1b}O\(c)" : "\u{1b}[\(c)"
        }
        func tilde(_ n: Int) -> String { mod > 1 ? "\u{1b}[\(n);\(mod)~" : "\u{1b}[\(n)~" }

        switch e.keyCode {
        case 36, 76: return option && Config.shared.optionAsAlt ? "\u{1b}\r" : "\r"
        case 48: return shift ? "\u{1b}[Z" : (control ? nil : "\t")
        case 51:
            if option { return "\u{1b}\u{7f}" }                       // delete word
            return control ? "\u{08}" : "\u{7f}"
        case 53: return "\u{1b}"
        case 126: return cursor("A")
        case 125: return cursor("B")
        case 124: return option && !shift && !control ? "\u{1b}f" : cursor("C")   // ⌥→ word right
        case 123: return option && !shift && !control ? "\u{1b}b" : cursor("D")   // ⌥← word left
        case 115: return mod > 1 ? "\u{1b}[1;\(mod)H" : (app ? "\u{1b}OH" : "\u{1b}[H")
        case 119: return mod > 1 ? "\u{1b}[1;\(mod)F" : (app ? "\u{1b}OF" : "\u{1b}[F")
        case 116: return tilde(5)
        case 121: return tilde(6)
        case 117: return tilde(3)
        case 114: return tilde(2)
        case 122: return mod > 1 ? "\u{1b}[1;\(mod)P" : "\u{1b}OP"
        case 120: return mod > 1 ? "\u{1b}[1;\(mod)Q" : "\u{1b}OQ"
        case 99: return mod > 1 ? "\u{1b}[1;\(mod)R" : "\u{1b}OR"
        case 118: return mod > 1 ? "\u{1b}[1;\(mod)S" : "\u{1b}OS"
        case 96: return tilde(15)
        case 97: return tilde(17)
        case 98: return tilde(18)
        case 100: return tilde(19)
        case 101: return tilde(20)
        case 109: return tilde(21)
        case 103: return tilde(23)
        case 111: return tilde(24)
        default: return nil
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        guard !text.isEmpty else { return }
        userTyped()
        send(text)
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): send("\r")
        case #selector(insertTab(_:)): send("\t")
        case #selector(deleteBackward(_:)): send("\u{7f}")
        case #selector(cancelOperation(_:)): send("\u{1b}")
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let r = convert(cursorRect(), to: nil)
        return window.convertToScreen(r)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Clipboard & menu actions

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        userTyped()
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.bracketedPaste {
            text = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
            send("\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(text)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        let first = terminal.droppedLines
        let last = terminal.droppedLines + terminal.scrollback.count + terminal.rows - 1
        selMode = .char
        selAnchor = GridPoint(row: first, col: 0)
        selHead = GridPoint(row: last, col: terminal.cols)
        needsDisplay = true
    }

    @objc func clearBuffer(_ sender: Any?) {
        if terminal.isAltScreen { return }
        terminal.clearScreenAndScrollback()
        scrollOffset = 0
        clearSelection()
        send("\u{0c}")
        needsDisplay = true
        delegate?.terminalViewStateDidChange(self)
    }

    @objc func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { setFontSize(Config.shared.fontSize) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(48, max(7, size))
        configureFonts()
        updateGrid()
        needsDisplay = true
    }

    @objc func scrollToTop(_ sender: Any?) { scrollBy(lines: terminal.scrollback.count) }
    @objc func scrollToBottom(_ sender: Any?) { scrollBy(lines: -scrollOffset) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectionRange() != nil }
        return true
    }

    // MARK: Scrolling

    private func scrollBy(lines: Int) {
        let new = min(max(0, scrollOffset + lines), terminal.scrollback.count)
        guard new != scrollOffset else { return }
        scrollOffset = new
        needsDisplay = true
        delegate?.terminalViewStateDidChange(self)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY * 3
        scrollRemainder += dy
        let lines = Int(scrollRemainder)
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines)

        if terminal.mouseTracking != .off && !event.modifierFlags.contains(.shift) {
            let (col, row) = cellPosition(event)
            for _ in 0..<min(abs(lines), 10) {
                reportMouse(button: lines > 0 ? 64 : 65, col: col, row: row, release: false, motion: false, event: event)
            }
        } else if terminal.isAltScreen {
            // Alternate-scroll: wheel becomes arrow keys in full-screen programs.
            let key = lines > 0 ? (terminal.applicationCursorKeys ? "\u{1b}OA" : "\u{1b}[A")
                                : (terminal.applicationCursorKeys ? "\u{1b}OB" : "\u{1b}[B")
            send(String(repeating: key, count: min(abs(lines), 10)))
        } else {
            scrollBy(lines: lines)
        }
    }

    // MARK: Mouse

    private func cellPosition(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let col = Int(floor((p.x - padX) / cellWidth))
        let row = Int(floor((p.y - padY) / cellHeight))
        return (min(max(col, 0), terminal.cols - 1), min(max(row, 0), terminal.rows - 1))
    }

    private func gridPoint(_ event: NSEvent, rounding: Bool) -> GridPoint {
        let p = convert(event.locationInWindow, from: nil)
        let fx = (p.x - padX) / cellWidth
        let fy = (p.y - padY) / cellHeight
        let col = rounding ? Int(round(fx)) : Int(floor(fx))
        let row = min(max(Int(floor(fy)), 0), terminal.rows - 1)
        return GridPoint(row: terminal.droppedLines + topCombinedIndex + row,
                         col: min(max(col, 0), rounding ? terminal.cols : terminal.cols - 1))
    }

    private var shouldReportMouse: Bool { terminal.mouseTracking != .off }

    private func reportMouse(button: Int, col: Int, row: Int, release: Bool, motion: Bool, event: NSEvent) {
        let m = event.modifierFlags
        var code = button + (motion ? 32 : 0)
        if m.contains(.shift) { code += 4 }
        if m.contains(.option) { code += 8 }
        if m.contains(.control) { code += 16 }
        if terminal.mouseSGR {
            send("\u{1b}[<\(code);\(col + 1);\(row + 1)\(release ? "m" : "M")")
        } else {
            let c = release ? 3 + (code & ~3) : code
            guard col < 223, row < 223 else { return }
            let bytes: [UInt8] = [0x1b, 0x5b, 0x4d, UInt8(32 + c), UInt8(33 + col), UInt8(33 + row)]
            pty?.write(bytes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldReportMouse && !event.modifierFlags.contains(.shift) {
            let (c, r) = cellPosition(event)
            lastMouseButton = 0
            reportMouse(button: 0, col: c, row: r, release: false, motion: false, event: event)
            return
        }
        if event.modifierFlags.contains(.command), openURL(at: event) { return }

        mouseIsSelecting = true
        switch event.clickCount {
        case 2:
            selMode = .word
            selAnchor = gridPoint(event, rounding: false); selHead = selAnchor
        case 3...:
            selMode = .line
            selAnchor = gridPoint(event, rounding: false); selHead = selAnchor
        default:
            if event.modifierFlags.contains(.shift), selAnchor != nil {
                selHead = gridPoint(event, rounding: true)
            } else {
                selMode = .char
                selAnchor = gridPoint(event, rounding: true); selHead = selAnchor
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if shouldReportMouse && !event.modifierFlags.contains(.shift) {
            if terminal.mouseTracking == .button || terminal.mouseTracking == .any {
                let (c, r) = cellPosition(event)
                reportMouse(button: lastMouseButton, col: c, row: r, release: false, motion: true, event: event)
            }
            return
        }
        guard mouseIsSelecting else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.y < padY { scrollBy(lines: 1) } else if p.y > bounds.height - padY { scrollBy(lines: -1) }
        selHead = gridPoint(event, rounding: selMode == .char)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if shouldReportMouse && !event.modifierFlags.contains(.shift) {
            if terminal.mouseTracking != .x10 {
                let (c, r) = cellPosition(event)
                reportMouse(button: 0, col: c, row: r, release: true, motion: false, event: event)
            }
            return
        }
        mouseIsSelecting = false
        if selectionRange() == nil { clearSelection() }
        else if Config.shared.copyOnSelect { copy(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if shouldReportMouse && !event.modifierFlags.contains(.shift) {
            let (c, r) = cellPosition(event)
            lastMouseButton = 2
            reportMouse(button: 2, col: c, row: r, release: false, motion: false, event: event)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if shouldReportMouse && terminal.mouseTracking != .x10 {
            let (c, r) = cellPosition(event)
            reportMouse(button: 2, col: c, row: r, release: true, motion: false, event: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if shouldReportMouse && !event.modifierFlags.contains(.shift) { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear", action: #selector(clearBuffer(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Selection

    private func clearSelection() {
        selAnchor = nil; selHead = nil
        needsDisplay = true
    }

    private func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "-_./~:@%+#?=&".contains(c)
    }

    private func selectionRange() -> (GridPoint, GridPoint)? {
        guard let a = selAnchor, let h = selHead else { return nil }
        var s = min(a, h), e = max(a, h)
        switch selMode {
        case .char:
            if s == e { return nil }
        case .word:
            if let line = terminal.line(atAbsolute: s.row), s.col < line.cells.count {
                var x = s.col
                if isWordChar(line.cells[x].ch) {
                    while x > 0 && isWordChar(line.cells[x - 1].ch) { x -= 1 }
                }
                s.col = x
            }
            if let line = terminal.line(atAbsolute: e.row), e.col < line.cells.count {
                var x = e.col
                if isWordChar(line.cells[x].ch) {
                    while x < line.cells.count - 1 && isWordChar(line.cells[x + 1].ch) { x += 1 }
                } else if line.cells[x].width == 2 {
                    x += 1
                }
                e.col = x + 1
            }
        case .line:
            s.col = 0
            e.col = terminal.cols
        }
        return (s, e)
    }

    private func selectedText() -> String? {
        guard let (s, e) = selectionRange() else { return nil }
        var out = ""
        for row in s.row...e.row {
            guard let line = terminal.line(atAbsolute: row) else { continue }
            let c0 = row == s.row ? s.col : 0
            let c1 = min(row == e.row ? e.col : line.cells.count, line.cells.count)
            var text = ""
            if c0 < c1 {
                for x in c0..<c1 where line.cells[x].width != 0 { text.append(line.cells[x].ch) }
            }
            if !(line.wrapped && row != e.row) {
                while text.last == " " { text.removeLast() }
            }
            out += text
            if row != e.row && !line.wrapped { out += "\n" }
        }
        return out
    }

    // MARK: Directories

    /// True when the shell itself (not vim, ssh, …) owns the foreground.
    var isShellIdle: Bool {
        guard let pty else { return false }
        let shell = (pty.shellPath as NSString).lastPathComponent
        guard let fg = pty.foregroundProcessName else { return true }
        return fg == shell || fg == "-" + shell || fg == "login"
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Types `cd <path>` into the shell, replacing whatever is on the prompt line.
    func changeDirectory(to path: String) {
        guard isShellIdle else { return }
        userTyped()
        send("\u{15}cd -- \(TerminalView.shellQuote(path))\r")
        window?.makeFirstResponder(self)
    }

    /// Types `command` into the shell and runs it, replacing whatever is on the prompt line.
    func runCommand(_ command: String) {
        userTyped()
        send("\u{15}\(command)\r")
        window?.makeFirstResponder(self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    /// Dropping a single folder while the shell is idle changes into it;
    /// anything else is pasted as quoted paths.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        else { return false }
        var isDir: ObjCBool = false
        if urls.count == 1, isShellIdle,
           FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir), isDir.boolValue {
            changeDirectory(to: urls[0].path)
        } else {
            userTyped()
            send(urls.map { TerminalView.shellQuote($0.path) }.joined(separator: " ") + " ")
        }
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Links

    private func openURL(at event: NSEvent) -> Bool {
        let (col, row) = cellPosition(event)
        guard let line = terminal.line(atCombined: topCombinedIndex + row) else { return false }
        var text = ""
        var offsets: [Int] = []      // utf16 offset at which each column starts
        for cell in line.cells {
            offsets.append(text.utf16.count)
            if cell.width != 0 { text.append(cell.ch) }
        }
        guard col < offsets.count,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return false }
        let target = offsets[col]
        for match in detector.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if NSLocationInRange(target, match.range), let url = match.url {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }
}

// MARK: - Box drawing

/// Pixel-perfect box drawing, block elements and Powerline separators, so lines join
/// across cells regardless of font or line height.
enum BoxDrawing {
    /// up/down/left/right weights for U+2500…U+257F (0 none, 1 light, 2 heavy, 3 double;
    /// R = rounded corner, X = diagonal).
    private static let table: [String] = """
    0011 0022 1100 2200 0011 0022 1100 2200 0011 0022 1100 2200 0101 0102 0201 0202
    0110 0120 0210 0220 1001 1002 2001 2002 1010 1020 2010 2020 1101 1102 2101 1201
    2201 2102 1202 2202 1110 1120 2110 1210 2210 2120 1220 2220 0111 0121 0112 0122
    0211 0221 0212 0222 1011 1021 1012 1022 2011 2021 2012 2022 1111 1121 1112 1122
    2111 1211 2211 2121 2112 1221 1212 2122 1222 2221 2212 2222 0011 0022 1100 2200
    0033 3300 0103 0301 0303 0130 0310 0330 1003 3001 3003 1030 3010 3030 1103 3301
    3303 1130 3310 3330 0133 0311 0333 1033 3011 3033 1133 3311 3333 R R R
    R X X X 0010 1000 0001 0100 0020 2000 0002 0200 0012 1200 0021 2100
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    static func handles(_ v: UInt32) -> Bool {
        (v >= 0x2500 && v <= 0x259F) || (v >= 0xE0B0 && v <= 0xE0B3)
    }

    static func draw(_ v: UInt32, rect r: CGRect, color: CGColor, light: CGFloat, ctx: CGContext) {
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        if v >= 0xE0B0 { powerline(v, r, light, ctx); return }
        if v >= 0x2580 { block(v, r, color, ctx); return }

        let spec = table[Int(v - 0x2500)]
        let cx = floor(r.midX), cy = floor(r.midY)
        if spec == "R" { rounded(v, r, cx, cy, light, ctx); return }
        if spec == "X" {
            ctx.setLineWidth(light)
            if v == 0x2571 || v == 0x2573 {
                ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            }
            if v == 0x2572 || v == 0x2573 {
                ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            }
            ctx.strokePath()
            return
        }

        let w = spec.utf8.map { Int($0) - 48 }   // u d l r
        let heavy = light * 2
        let g = max(light * 1.5, round(r.width / 7))      // half-distance between double strokes
        func thick(_ wt: Int) -> CGFloat { wt == 2 ? heavy : (wt == 0 ? 0 : light) }
        let vDouble = w[0] == 3 || w[1] == 3
        let hDouble = w[2] == 3 || w[3] == 3
        let vThick = max(thick(w[0] == 3 ? 1 : w[0]), thick(w[1] == 3 ? 1 : w[1]))
        let hThick = max(thick(w[2] == 3 ? 1 : w[2]), thick(w[3] == 3 ? 1 : w[3]))

        func vline(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat, _ t: CGFloat) {
            ctx.fill(CGRect(x: x - t / 2, y: min(a, b), width: t, height: abs(b - a)))
        }
        func hline(_ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ t: CGFloat) {
            ctx.fill(CGRect(x: min(a, b), y: y - t / 2, width: abs(b - a), height: t))
        }

        // "reach" is how far a stroke runs past the centre line before stopping.
        for (wt, up) in [(w[0], true), (w[1], false)] where wt > 0 {
            let edge = up ? r.minY : r.maxY
            if wt == 3 {
                for side: CGFloat in [-1, 1] {
                    let p = side < 0 ? w[2] : w[3]
                    let reach: CGFloat = p == 3 ? -g : (p > 0 ? 0 : g)
                    vline(cx + side * g, edge, up ? cy + reach : cy - reach, light)
                }
            } else {
                let reach = hDouble ? -g : max(thick(wt), hThick) / 2
                vline(cx, edge, up ? cy + reach : cy - reach, thick(wt))
            }
        }
        for (wt, left) in [(w[2], true), (w[3], false)] where wt > 0 {
            let edge = left ? r.minX : r.maxX
            if wt == 3 {
                for side: CGFloat in [-1, 1] {
                    let p = side < 0 ? w[0] : w[1]
                    let reach: CGFloat = p == 3 ? -g : (p > 0 ? 0 : g)
                    hline(cy + side * g, edge, left ? cx + reach : cx - reach, light)
                }
            } else {
                let reach = vDouble ? -g : max(thick(wt), vThick) / 2
                hline(cy, edge, left ? cx + reach : cx - reach, thick(wt))
            }
        }
    }

    private static func rounded(_ v: UInt32, _ r: CGRect, _ cx: CGFloat, _ cy: CGFloat, _ t: CGFloat, _ ctx: CGContext) {
        let center = CGPoint(x: cx, y: cy)
        let (a, b): (CGPoint, CGPoint)
        switch v {
        case 0x256D: (a, b) = (CGPoint(x: r.maxX, y: cy), CGPoint(x: cx, y: r.maxY))   // ╭
        case 0x256E: (a, b) = (CGPoint(x: r.minX, y: cy), CGPoint(x: cx, y: r.maxY))   // ╮
        case 0x256F: (a, b) = (CGPoint(x: r.minX, y: cy), CGPoint(x: cx, y: r.minY))   // ╯
        default:     (a, b) = (CGPoint(x: r.maxX, y: cy), CGPoint(x: cx, y: r.minY))   // ╰
        }
        ctx.setLineWidth(t)
        ctx.move(to: a)
        ctx.addArc(tangent1End: center, tangent2End: b, radius: min(r.width, r.height) / 2)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    private static func block(_ v: UInt32, _ r: CGRect, _ color: CGColor, _ ctx: CGContext) {
        let w = r.width, h = r.height
        func fill(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            ctx.fill(CGRect(x: r.minX + x0 * w, y: r.minY + y0 * h, width: (x1 - x0) * w, height: (y1 - y0) * h))
        }
        switch v {
        case 0x2580: fill(0, 0, 1, 0.5)
        case 0x2581...0x2587: fill(0, 1 - CGFloat(v - 0x2580) / 8, 1, 1)
        case 0x2588: fill(0, 0, 1, 1)
        case 0x2589...0x258F: fill(0, 0, CGFloat(0x2590 - v) / 8, 1)
        case 0x2590: fill(0.5, 0, 1, 1)
        case 0x2591, 0x2592, 0x2593:
            ctx.setFillColor(color.copy(alpha: CGFloat(v - 0x2590) * 0.25) ?? color)
            fill(0, 0, 1, 1)
        case 0x2594: fill(0, 0, 1, 0.125)
        case 0x2595: fill(0.875, 0, 1, 1)
        default:
            // Quadrants U+2596…U+259F as bitmasks: UL=1 UR=2 LL=4 LR=8
            let masks: [UInt32: Int] = [0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 13, 0x259A: 9,
                                        0x259B: 7, 0x259C: 11, 0x259D: 2, 0x259E: 6, 0x259F: 14]
            let m = masks[v] ?? 0
            if m & 1 != 0 { fill(0, 0, 0.5, 0.5) }
            if m & 2 != 0 { fill(0.5, 0, 1, 0.5) }
            if m & 4 != 0 { fill(0, 0.5, 0.5, 1) }
            if m & 8 != 0 { fill(0.5, 0.5, 1, 1) }
        }
    }

    private static func powerline(_ v: UInt32, _ r: CGRect, _ t: CGFloat, _ ctx: CGContext) {
        let right = v == 0xE0B0 || v == 0xE0B1
        let tip = right ? CGPoint(x: r.maxX, y: r.midY) : CGPoint(x: r.minX, y: r.midY)
        let x0 = right ? r.minX : r.maxX
        ctx.move(to: CGPoint(x: x0, y: r.minY))
        ctx.addLine(to: tip)
        ctx.addLine(to: CGPoint(x: x0, y: r.maxY))
        if v == 0xE0B0 || v == 0xE0B2 {
            ctx.closePath()
            ctx.fillPath()
        } else {
            ctx.setLineWidth(t)
            ctx.strokePath()
        }
    }
}

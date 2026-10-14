import Foundation

// MARK: - Cell model

enum TermColor: Equatable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct Attr: Equatable {
    var fg: TermColor = .default
    var bg: TermColor = .default
    var flags: UInt16 = 0

    static let bold: UInt16 = 1 << 0
    static let dim: UInt16 = 1 << 1
    static let italic: UInt16 = 1 << 2
    static let underline: UInt16 = 1 << 3
    static let inverse: UInt16 = 1 << 4
    static let strike: UInt16 = 1 << 5
    static let hidden: UInt16 = 1 << 6
    static let blink: UInt16 = 1 << 7
    static let doubleUnderline: UInt16 = 1 << 8

    @inline(__always) func has(_ f: UInt16) -> Bool { flags & f != 0 }
    @inline(__always) mutating func set(_ f: UInt16, _ on: Bool) {
        if on { flags |= f } else { flags &= ~f }
    }
}

struct Cell {
    var ch: Character
    var attr: Attr
    /// 1 = normal, 2 = leading half of a wide glyph, 0 = trailing half.
    var width: UInt8

    static let blank = Cell(ch: " ", attr: Attr(), width: 1)
}

struct Line {
    var cells: [Cell]
    var wrapped = false

    init(cols: Int, fill: Cell = .blank) {
        cells = Array(repeating: fill, count: cols)
    }

    mutating func fit(_ cols: Int) {
        if cells.count > cols {
            cells.removeLast(cells.count - cols)
            if let last = cells.last, last.width == 2 { cells[cells.count - 1] = .blank }
        } else if cells.count < cols {
            cells.append(contentsOf: repeatElement(Cell.blank, count: cols - cells.count))
        }
    }
}

enum MouseTracking { case off, x10, normal, button, any }
enum CursorShape { case block, underline, bar }

protocol TerminalDelegate: AnyObject {
    func terminal(_ terminal: Terminal, send bytes: [UInt8])
    func terminalTitleDidChange(_ terminal: Terminal)
    func terminalBell(_ terminal: Terminal)
    func terminal(_ terminal: Terminal, setClipboard text: String)
    /// 0-255 palette entries, 256 = foreground, 257 = background, 258 = cursor.
    func terminal(_ terminal: Terminal, colorFor slot: Int) -> (UInt8, UInt8, UInt8)?
}

// MARK: - Terminal state machine

/// An xterm-compatible screen model and escape-sequence parser.
final class Terminal {
    weak var delegate: TerminalDelegate?

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var screen: [Line]
    private(set) var scrollback: [Line] = []
    var scrollbackLimit = 10_000
    /// Lines trimmed off the front of the scrollback, so absolute row indices stay stable.
    private(set) var droppedLines = 0
    private var pushedLines = 0
    private var savedMainScreen: [Line]?
    var isAltScreen: Bool { savedMainScreen != nil }

    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private var pendingWrap = false
    private var attr = Attr()

    private struct SavedCursor {
        var x: Int, y: Int
        var attr: Attr
        var pendingWrap: Bool
        var originMode: Bool
        var g0: Bool, g1: Bool, useG1: Bool
    }
    private var savedCursor: SavedCursor?

    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: [Bool]

    private(set) var autowrap = true
    private(set) var insertMode = false
    private(set) var originMode = false
    private(set) var newLineMode = false
    private(set) var applicationCursorKeys = false
    private(set) var applicationKeypad = false
    private(set) var cursorVisible = true
    private(set) var bracketedPaste = false
    private(set) var mouseTracking: MouseTracking = .off
    private(set) var mouseSGR = false
    private(set) var focusReporting = false
    private(set) var reverseVideo = false
    /// Shape requested by the running program (DECSCUSR); nil means "use the configured default".
    private(set) var cursorShape: CursorShape?
    private(set) var title = ""

    private var g0Graphics = false
    private var g1Graphics = false
    private var useG1 = false
    private var lastPrinted: Character?
    private var lastWasZWJ = false

    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape, string, stringEscape }
    private var state: State = .ground
    private var utf8Remaining = 0
    private var utf8Value: UInt32 = 0
    private var escIntermediate: UInt8 = 0
    private var csiPrivate: UInt8 = 0
    private var csiIntermediate: UInt8 = 0
    private var csiParams: [UInt8] = []
    private var oscBuffer: [UInt8] = []

    init(cols: Int, rows: Int) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        screen = []
        scrollBottom = 0
        tabStops = []
        screen = (0..<self.rows).map { _ in Line(cols: self.cols) }
        scrollBottom = self.rows - 1
        tabStops = Terminal.defaultTabs(self.cols)
    }

    private static func defaultTabs(_ cols: Int) -> [Bool] {
        (0..<cols).map { $0 % 8 == 0 && $0 != 0 }
    }

    // MARK: Buffer access

    /// Index into scrollback followed by screen.
    func line(atCombined i: Int) -> Line? {
        if i < 0 { return nil }
        if i < scrollback.count { return scrollback[i] }
        let s = i - scrollback.count
        return s < screen.count ? screen[s] : nil
    }

    func line(atAbsolute a: Int) -> Line? { line(atCombined: a - droppedLines) }

    /// Number of lines pushed into scrollback since the last call.
    func takePushedLines() -> Int {
        defer { pushedLines = 0 }
        return pushedLines
    }

    func clearScrollback() {
        droppedLines += scrollback.count
        scrollback.removeAll()
    }

    /// Cmd-K: wipe history and screen but keep the cursor's line at the top.
    func clearScreenAndScrollback() {
        clearScrollback()
        guard !isAltScreen else { return }
        let keep = screen[cursorY]
        screen = (0..<rows).map { _ in Line(cols: cols) }
        screen[0] = keep
        cursorY = 0
    }

    // MARK: Feeding

    func feed(_ bytes: UnsafeRawBufferPointer) {
        for b in bytes { step(b) }
    }

    func feed(_ string: String) {
        var s = string
        s.withUTF8 { feed(UnsafeRawBufferPointer($0)) }
    }

    @inline(__always) private func step(_ b: UInt8) {
        switch state {
        case .ground:
            if utf8Remaining > 0 {
                if b & 0xC0 == 0x80 {
                    utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                    utf8Remaining -= 1
                    if utf8Remaining == 0 { printScalar(utf8Value) }
                    return
                }
                utf8Remaining = 0
                printScalar(0xFFFD)
            }
            if b >= 0x20 && b < 0x7F {
                printScalar(UInt32(b))
            } else if b < 0x20 {
                execute(b)
            } else if b == 0x7F {
                // DEL is ignored
            } else if b & 0xE0 == 0xC0 {
                utf8Value = UInt32(b & 0x1F); utf8Remaining = 1
            } else if b & 0xF0 == 0xE0 {
                utf8Value = UInt32(b & 0x0F); utf8Remaining = 2
            } else if b & 0xF8 == 0xF0 {
                utf8Value = UInt32(b & 0x07); utf8Remaining = 3
            } else {
                printScalar(0xFFFD)
            }

        case .escape:
            escape(b)

        case .escapeIntermediate:
            state = .ground
            if b < 0x20 { execute(b); return }
            switch escIntermediate {
            case 0x28: g0Graphics = (b == 0x30)       // ESC ( 0
            case 0x29: g1Graphics = (b == 0x30)       // ESC ) 0
            case 0x23 where b == 0x38: alignmentTest() // ESC # 8
            default: break
            }

        case .csi:
            if b == 0x1B { state = .escape }
            else if b == 0x18 || b == 0x1A { state = .ground }
            else if b < 0x20 { execute(b) }
            else if b >= 0x3C && b <= 0x3F && csiParams.isEmpty && csiPrivate == 0 { csiPrivate = b }
            else if b >= 0x30 && b <= 0x3F { csiParams.append(b) }
            else if b >= 0x20 && b <= 0x2F { csiIntermediate = b }
            else if b >= 0x40 && b <= 0x7E { state = .ground; dispatchCSI(b) }

        case .osc:
            if b == 0x07 { state = .ground; handleOSC() }
            else if b == 0x1B { state = .oscEscape }
            else if b == 0x18 || b == 0x1A { state = .ground }
            else if b >= 0x20 && oscBuffer.count < 1 << 20 { oscBuffer.append(b) }

        case .oscEscape:
            state = .ground
            handleOSC()
            if b != 0x5C { state = .escape; escape(b) }

        case .string:
            if b == 0x1B { state = .stringEscape }
            else if b == 0x07 || b == 0x18 || b == 0x1A { state = .ground }

        case .stringEscape:
            state = .ground
            if b != 0x5C { state = .escape; escape(b) }
        }
    }

    private func execute(_ b: UInt8) {
        switch b {
        case 0x07: delegate?.terminalBell(self)
        case 0x08:
            if cursorX > 0 { cursorX -= 1 }
            pendingWrap = false
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if newLineMode { cursorX = 0 }
        case 0x0D:
            cursorX = 0; pendingWrap = false
        case 0x0E: useG1 = true
        case 0x0F: useG1 = false
        case 0x1B: state = .escape
        default: break
        }
    }

    private func escape(_ b: UInt8) {
        state = .ground
        if b == 0x1B { state = .escape; return }
        if b == 0x18 || b == 0x1A { return }
        if b < 0x20 { execute(b); state = .escape; return }
        if b <= 0x2F { escIntermediate = b; state = .escapeIntermediate; return }
        switch Character(Unicode.Scalar(b)) {
        case "[":
            csiParams.removeAll(keepingCapacity: true)
            csiPrivate = 0; csiIntermediate = 0
            state = .csi
        case "]":
            oscBuffer.removeAll(keepingCapacity: true)
            state = .osc
        case "P", "X", "^", "_": state = .string
        case "7": saveCursor()
        case "8": restoreCursor()
        case "D": index()
        case "E": cursorX = 0; index()
        case "M": reverseIndex()
        case "H": tabStops[cursorX] = true
        case "c": reset()
        case "=": applicationKeypad = true
        case ">": applicationKeypad = false
        default: break
        }
    }

    // MARK: Printing

    private static let decSpecial: [Character] = Array("\u{00A0}◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·")

    private func printScalar(_ v: UInt32) {
        guard let scalar = Unicode.Scalar(v) else { return }
        let graphics = useG1 ? g1Graphics : g0Graphics
        if graphics && v >= 0x5F && v <= 0x7E {
            put(Terminal.decSpecial[Int(v - 0x5F)], width: 1)
            lastWasZWJ = false
            return
        }
        let w = charWidth(v)
        if w == 0 || lastWasZWJ {
            combine(scalar)
            lastWasZWJ = (v == 0x200D)
            return
        }
        put(Character(scalar), width: w)
    }

    private func combine(_ s: Unicode.Scalar) {
        var x = pendingWrap ? cursorX : cursorX - 1
        guard x >= 0, cursorY < rows else { return }
        if screen[cursorY].cells[x].width == 0 && x > 0 { x -= 1 }
        var str = String(screen[cursorY].cells[x].ch)
        str.unicodeScalars.append(s)
        if str.count == 1 { screen[cursorY].cells[x].ch = Character(str) }
    }

    @inline(__always) private func blankCell() -> Cell {
        Cell(ch: " ", attr: Attr(fg: .default, bg: attr.bg, flags: 0), width: 1)
    }

    private func blankLine() -> Line { Line(cols: cols, fill: blankCell()) }

    private func put(_ ch: Character, width w: Int) {
        if pendingWrap {
            if autowrap {
                screen[cursorY].wrapped = true
                cursorX = 0
                index()
            }
            pendingWrap = false
        }
        if w == 2 && cursorX >= cols - 1 {
            if autowrap {
                screen[cursorY].cells[cols - 1] = blankCell()
                screen[cursorY].wrapped = true
                cursorX = 0
                index()
            } else {
                return
            }
        }
        if insertMode { insertBlanks(w) }
        splitWide(at: cursorX)
        screen[cursorY].cells[cursorX] = Cell(ch: ch, attr: attr, width: UInt8(w))
        if w == 2 {
            splitWide(at: cursorX + 1)
            screen[cursorY].cells[cursorX + 1] = Cell(ch: " ", attr: attr, width: 0)
        }
        lastPrinted = ch
        lastWasZWJ = false
        let nx = cursorX + w
        if nx >= cols {
            cursorX = cols - 1
            pendingWrap = true
        } else {
            cursorX = nx
        }
    }

    /// Overwriting either half of a wide glyph blanks the other half.
    private func splitWide(at x: Int) {
        guard x < cols else { return }
        let c = screen[cursorY].cells[x]
        if c.width == 2 && x + 1 < cols { screen[cursorY].cells[x + 1] = blankCell() }
        if c.width == 0 && x > 0 { screen[cursorY].cells[x - 1] = blankCell() }
    }

    // MARK: Scrolling

    private func appendScrollback(_ line: Line) {
        scrollback.append(line)
        pushedLines += 1
        // Trim in chunks so we don't memmove the whole history on every line.
        if scrollback.count > scrollbackLimit + 512 {
            let excess = scrollback.count - scrollbackLimit
            scrollback.removeFirst(excess)
            droppedLines += excess
        }
    }

    private func scrollUp(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            let line = screen.remove(at: scrollTop)
            if scrollTop == 0 && !isAltScreen { appendScrollback(line) }
            screen.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine(), at: scrollTop)
        }
    }

    private func index() {
        pendingWrap = false
        if cursorY == scrollBottom { scrollUp(1) }
        else if cursorY < rows - 1 { cursorY += 1 }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorY == scrollTop { scrollDown(1) }
        else if cursorY > 0 { cursorY -= 1 }
    }

    // MARK: Editing

    private func insertBlanks(_ n: Int) {
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        screen[cursorY].cells.insert(contentsOf: repeatElement(blankCell(), count: n), at: cursorX)
        screen[cursorY].cells.removeLast(n)
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        screen[cursorY].cells.removeSubrange(cursorX..<(cursorX + n))
        screen[cursorY].cells.append(contentsOf: repeatElement(blankCell(), count: n))
    }

    private func eraseCells(_ y: Int, _ from: Int, _ to: Int) {
        let from = max(0, from), to = min(cols, to)
        guard from < to else { return }
        let blank = blankCell()
        for x in from..<to { screen[y].cells[x] = blank }
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine(), at: cursorY)
        }
        cursorX = 0; pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n {
            screen.remove(at: cursorY)
            screen.insert(blankLine(), at: scrollBottom)
        }
        cursorX = 0; pendingWrap = false
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseCells(cursorY, cursorX, cols)
            for y in (cursorY + 1)..<max(cursorY + 1, rows) { screen[y] = blankLine() }
        case 1:
            for y in 0..<cursorY { screen[y] = blankLine() }
            eraseCells(cursorY, 0, cursorX + 1)
        case 2:
            for y in 0..<rows { screen[y] = blankLine() }
        case 3:
            clearScrollback()
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0: eraseCells(cursorY, cursorX, cols)
        case 1: eraseCells(cursorY, 0, cursorX + 1)
        case 2: eraseCells(cursorY, 0, cols)
        default: break
        }
    }

    private func alignmentTest() {
        for y in 0..<rows {
            screen[y] = Line(cols: cols, fill: Cell(ch: "E", attr: Attr(), width: 1))
        }
        cursorX = 0; cursorY = 0
    }

    // MARK: Cursor

    private func setCursor(row: Int, col: Int) {
        if originMode {
            cursorY = min(max(row + scrollTop, scrollTop), scrollBottom)
        } else {
            cursorY = min(max(row, 0), rows - 1)
        }
        cursorX = min(max(col, 0), cols - 1)
        pendingWrap = false
    }

    private func moveUp(_ n: Int) {
        let limit = cursorY >= scrollTop ? scrollTop : 0
        cursorY = max(limit, cursorY - n); pendingWrap = false
    }

    private func moveDown(_ n: Int) {
        let limit = cursorY <= scrollBottom ? scrollBottom : rows - 1
        cursorY = min(limit, cursorY + n); pendingWrap = false
    }

    private func tabForward(_ n: Int) {
        for _ in 0..<max(1, n) {
            var x = cursorX + 1
            while x < cols - 1 && !tabStops[x] { x += 1 }
            cursorX = min(x, cols - 1)
        }
        pendingWrap = false
    }

    private func tabBackward(_ n: Int) {
        for _ in 0..<max(1, n) {
            var x = cursorX - 1
            while x > 0 && !tabStops[x] { x -= 1 }
            cursorX = max(x, 0)
        }
        pendingWrap = false
    }

    private func saveCursor() {
        savedCursor = SavedCursor(x: cursorX, y: cursorY, attr: attr, pendingWrap: pendingWrap,
                                  originMode: originMode, g0: g0Graphics, g1: g1Graphics, useG1: useG1)
    }

    private func restoreCursor() {
        guard let s = savedCursor else {
            cursorX = 0; cursorY = 0; attr = Attr(); originMode = false
            return
        }
        cursorX = min(s.x, cols - 1)
        cursorY = min(s.y, rows - 1)
        attr = s.attr
        pendingWrap = s.pendingWrap
        originMode = s.originMode
        g0Graphics = s.g0; g1Graphics = s.g1; useG1 = s.useG1
    }

    private func enterAltScreen() {
        guard !isAltScreen else { return }
        savedMainScreen = screen
        screen = (0..<rows).map { _ in Line(cols: cols) }
    }

    private func exitAltScreen() {
        guard let main = savedMainScreen else { return }
        screen = main
        savedMainScreen = nil
    }

    // MARK: Reset

    private func reset() {
        exitAltScreen()
        attr = Attr()
        screen = (0..<rows).map { _ in Line(cols: cols) }
        cursorX = 0; cursorY = 0; pendingWrap = false
        scrollTop = 0; scrollBottom = rows - 1
        tabStops = Terminal.defaultTabs(cols)
        autowrap = true; insertMode = false; originMode = false; newLineMode = false
        applicationCursorKeys = false; applicationKeypad = false
        cursorVisible = true; bracketedPaste = false
        mouseTracking = .off; mouseSGR = false; focusReporting = false
        reverseVideo = false; cursorShape = nil
        g0Graphics = false; g1Graphics = false; useG1 = false
        savedCursor = nil
    }

    private func softReset() {
        attr = Attr()
        cursorVisible = true; originMode = false; autowrap = true; insertMode = false
        applicationCursorKeys = false; applicationKeypad = false
        scrollTop = 0; scrollBottom = rows - 1
        g0Graphics = false; g1Graphics = false; useG1 = false
        savedCursor = nil; pendingWrap = false
    }

    // MARK: Resize

    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }

        if newCols != cols {
            for i in screen.indices { screen[i].fit(newCols) }
            if savedMainScreen != nil {
                for i in savedMainScreen!.indices { savedMainScreen![i].fit(newCols) }
            }
            cols = newCols
            tabStops = Terminal.defaultTabs(newCols)
        }

        if newRows < rows {
            var excess = rows - newRows
            // Drop rows below the cursor first, then push the top into history.
            while excess > 0 && screen.count - 1 > cursorY {
                screen.removeLast(); excess -= 1
            }
            if excess > 0 {
                let top = screen.prefix(excess)
                screen.removeFirst(excess)
                if !isAltScreen { top.forEach(appendScrollback) }
                cursorY -= excess
            }
            if var main = savedMainScreen {
                let drop = main.count - newRows
                if drop > 0 {
                    main.prefix(drop).forEach(appendScrollback)
                    main.removeFirst(drop)
                    if savedCursor != nil { savedCursor!.y = max(0, savedCursor!.y - drop) }
                }
                savedMainScreen = main
            }
        } else if newRows > rows {
            var need = newRows - rows
            if !isAltScreen {
                while need > 0, var l = scrollback.popLast() {
                    l.fit(cols)
                    screen.insert(l, at: 0)
                    cursorY += 1
                    need -= 1
                }
            }
            for _ in 0..<need { screen.append(Line(cols: cols)) }
            if savedMainScreen != nil {
                while savedMainScreen!.count < newRows { savedMainScreen!.append(Line(cols: cols)) }
            }
        }

        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        cursorX = min(cursorX, cols - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
        pendingWrap = false
    }

    // MARK: CSI

    private func parseParams() -> [[Int]] {
        if csiParams.isEmpty { return [] }
        var out: [[Int]] = []
        var group: [Int] = []
        var cur = -1
        for b in csiParams {
            switch b {
            case 0x30...0x39:
                cur = (cur < 0 ? 0 : cur) &* 10 &+ Int(b - 0x30)
                if cur > 1_000_000 { cur = 1_000_000 }
            case 0x3A:
                group.append(cur); cur = -1
            case 0x3B:
                group.append(cur); out.append(group); group = []; cur = -1
            default: break
            }
        }
        group.append(cur)
        out.append(group)
        return out
    }

    private func respond(_ s: String) {
        delegate?.terminal(self, send: Array(s.utf8))
    }

    private func dispatchCSI(_ final: UInt8) {
        let params = parseParams()
        func arg(_ i: Int, _ def: Int) -> Int {
            guard i < params.count, let v = params[i].first, v > 0 else { return def }
            return v
        }
        let f = Character(Unicode.Scalar(final))

        if csiIntermediate == 0x20 {          // SP
            if f == "q" {                     // DECSCUSR
                switch arg(0, 0) {
                case 0: cursorShape = nil
                case 1, 2: cursorShape = .block
                case 3, 4: cursorShape = .underline
                case 5, 6: cursorShape = .bar
                default: break
                }
            }
            return
        }
        if csiIntermediate == 0x21 {          // !
            if f == "p" { softReset() }
            return
        }
        if csiIntermediate != 0 { return }

        switch csiPrivate {
        case 0x3F:                            // ?
            switch f {
            case "h": for p in params { setPrivateMode(p.first ?? 0, true) }
            case "l": for p in params { setPrivateMode(p.first ?? 0, false) }
            default: break
            }
            return
        case 0x3E:                            // >
            switch f {
            case "c": respond("\u{1b}[>1;10;0c")
            case "q": respond("\u{1b}P>|Ghosty 1.0\u{1b}\\")
            default: break
            }
            return
        case 0: break
        default: return
        }

        switch f {
        case "@": insertBlanks(arg(0, 1))
        case "A": moveUp(arg(0, 1))
        case "B", "e": moveDown(arg(0, 1))
        case "C", "a": cursorX = min(cols - 1, cursorX + arg(0, 1)); pendingWrap = false
        case "D": cursorX = max(0, min(cursorX, cols - 1) - arg(0, 1)); pendingWrap = false
        case "E": moveDown(arg(0, 1)); cursorX = 0
        case "F": moveUp(arg(0, 1)); cursorX = 0
        case "G", "`": cursorX = min(cols - 1, arg(0, 1) - 1); pendingWrap = false
        case "H", "f": setCursor(row: arg(0, 1) - 1, col: arg(1, 1) - 1)
        case "I": tabForward(arg(0, 1))
        case "J": eraseDisplay(arg(0, 0))
        case "K": eraseLine(arg(0, 0))
        case "L": insertLines(arg(0, 1))
        case "M": deleteLines(arg(0, 1))
        case "P": deleteChars(arg(0, 1))
        case "S": scrollUp(arg(0, 1))
        case "T": if params.count <= 1 { scrollDown(arg(0, 1)) }
        case "X": eraseCells(cursorY, cursorX, cursorX + arg(0, 1))
        case "Z": tabBackward(arg(0, 1))
        case "b":
            if let ch = lastPrinted {
                let w = charWidth(ch.unicodeScalars.first!.value)
                for _ in 0..<min(arg(0, 1), cols * rows) { put(ch, width: max(1, w)) }
            }
        case "c": if arg(0, 0) == 0 { respond("\u{1b}[?62;22c") }
        case "d":
            let row = arg(0, 1) - 1
            setCursor(row: row, col: cursorX)
        case "g":
            switch arg(0, 0) {
            case 0: tabStops[cursorX] = false
            case 3: tabStops = Array(repeating: false, count: cols)
            default: break
            }
        case "h", "l":
            let on = f == "h"
            for p in params {
                switch p.first ?? 0 {
                case 4: insertMode = on
                case 20: newLineMode = on
                default: break
                }
            }
        case "m": sgr(params)
        case "n":
            switch arg(0, 0) {
            case 5: respond("\u{1b}[0n")
            case 6:
                let row = cursorY + 1 - (originMode ? scrollTop : 0)
                respond("\u{1b}[\(row);\(cursorX + 1)R")
            default: break
            }
        case "r":
            let top = arg(0, 1) - 1
            let bottom = min(arg(1, rows), rows) - 1
            if top < bottom {
                scrollTop = top; scrollBottom = bottom
                setCursor(row: 0, col: 0)
            }
        case "s": saveCursor()
        case "u": restoreCursor()
        case "t":
            if arg(0, 0) == 18 { respond("\u{1b}[8;\(rows);\(cols)t") }
        default: break
        }
    }

    private func setPrivateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: applicationCursorKeys = on
        case 5: reverseVideo = on
        case 6: originMode = on; setCursor(row: 0, col: 0)
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 9: mouseTracking = on ? .x10 : .off
        case 1000: mouseTracking = on ? .normal : .off
        case 1002: mouseTracking = on ? .button : .off
        case 1003: mouseTracking = on ? .any : .off
        case 1004: focusReporting = on
        case 1006: mouseSGR = on
        case 47, 1047:
            if on { enterAltScreen() } else {
                if mode == 1047 { for y in 0..<rows { screen[y] = Line(cols: cols) } }
                exitAltScreen()
            }
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049:
            if on {
                saveCursor()
                enterAltScreen()
                cursorX = 0; cursorY = 0
            } else {
                exitAltScreen()
                restoreCursor()
            }
        case 2004: bracketedPaste = on
        default: break
        }
    }

    // MARK: SGR

    private func sgr(_ ps: [[Int]]) {
        if ps.isEmpty { attr = Attr(); return }
        var i = 0
        func extendedColor(_ g: [Int]) -> TermColor? {
            if g.count > 1 {
                // Colon form: 38:5:n or 38:2:[cs]:r:g:b
                if g[1] == 5, g.count > 2 { return .indexed(UInt8(clamping: max(0, g[2]))) }
                if g[1] == 2 {
                    let c = g.count >= 6 ? Array(g[3...5]) : (g.count >= 5 ? Array(g[2...4]) : [])
                    if c.count == 3 {
                        return .rgb(UInt8(clamping: max(0, c[0])), UInt8(clamping: max(0, c[1])), UInt8(clamping: max(0, c[2])))
                    }
                }
                return nil
            }
            // Semicolon form: 38;5;n or 38;2;r;g;b
            guard i + 1 < ps.count else { return nil }
            let kind = ps[i + 1].first ?? 0
            if kind == 5, i + 2 < ps.count {
                defer { i += 2 }
                return .indexed(UInt8(clamping: max(0, ps[i + 2].first ?? 0)))
            }
            if kind == 2, i + 4 < ps.count {
                defer { i += 4 }
                return .rgb(UInt8(clamping: max(0, ps[i + 2].first ?? 0)),
                            UInt8(clamping: max(0, ps[i + 3].first ?? 0)),
                            UInt8(clamping: max(0, ps[i + 4].first ?? 0)))
            }
            return nil
        }
        while i < ps.count {
            let g = ps[i]
            let p = max(0, g.first ?? 0)
            switch p {
            case 0: attr = Attr()
            case 1: attr.set(Attr.bold, true)
            case 2: attr.set(Attr.dim, true)
            case 3: attr.set(Attr.italic, true)
            case 4:
                let style = g.count > 1 ? g[1] : 1
                attr.set(Attr.underline, style != 0)
                attr.set(Attr.doubleUnderline, style == 2)
            case 5, 6: attr.set(Attr.blink, true)
            case 7: attr.set(Attr.inverse, true)
            case 8: attr.set(Attr.hidden, true)
            case 9: attr.set(Attr.strike, true)
            case 21: attr.set(Attr.underline, true); attr.set(Attr.doubleUnderline, true)
            case 22: attr.set(Attr.bold, false); attr.set(Attr.dim, false)
            case 23: attr.set(Attr.italic, false)
            case 24: attr.set(Attr.underline, false); attr.set(Attr.doubleUnderline, false)
            case 25: attr.set(Attr.blink, false)
            case 27: attr.set(Attr.inverse, false)
            case 28: attr.set(Attr.hidden, false)
            case 29: attr.set(Attr.strike, false)
            case 30...37: attr.fg = .indexed(UInt8(p - 30))
            case 38: if let c = extendedColor(g) { attr.fg = c }
            case 39: attr.fg = .default
            case 40...47: attr.bg = .indexed(UInt8(p - 40))
            case 48: if let c = extendedColor(g) { attr.bg = c }
            case 49: attr.bg = .default
            case 58: _ = extendedColor(g)   // underline colour: parsed and ignored
            case 90...97: attr.fg = .indexed(UInt8(p - 90 + 8))
            case 100...107: attr.bg = .indexed(UInt8(p - 100 + 8))
            default: break
            }
            i += 1
        }
    }

    // MARK: OSC

    private func handleOSC() {
        let s = String(decoding: oscBuffer, as: UTF8.self)
        let parts = s.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = Int(parts.first ?? "") else { return }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case 0, 2:
            title = rest
            delegate?.terminalTitleDidChange(self)
        case 4:
            // 4;index;? → report palette entry
            let f = rest.split(separator: ";")
            if f.count == 2, f[1] == "?", let idx = Int(f[0]),
               let c = delegate?.terminal(self, colorFor: idx) {
                respond("\u{1b}]4;\(idx);\(Terminal.rgbSpec(c))\u{1b}\\")
            }
        case 10, 11, 12:
            if rest == "?", let c = delegate?.terminal(self, colorFor: 256 + code - 10) {
                respond("\u{1b}]\(code);\(Terminal.rgbSpec(c))\u{1b}\\")
            }
        case 52:
            // 52;c;<base64>  — writes only; reading the clipboard is never allowed.
            let f = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if f.count == 2, f[1] != "?", let data = Data(base64Encoded: String(f[1])),
               let text = String(data: data, encoding: .utf8) {
                delegate?.terminal(self, setClipboard: text)
            }
        default: break
        }
    }

    private static func rgbSpec(_ c: (UInt8, UInt8, UInt8)) -> String {
        func h(_ v: UInt8) -> String { let s = String(format: "%02x", v); return s + s }
        return "rgb:\(h(c.0))/\(h(c.1))/\(h(c.2))"
    }
}

// MARK: - Character width

private let zeroWidthRanges: [ClosedRange<UInt32>] = [
    0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x0610...0x061A, 0x064B...0x065F,
    0x0E31...0x0E31, 0x0E34...0x0E3A, 0x0E47...0x0E4E, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF,
    0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x20D0...0x20FF, 0xFE00...0xFE0F,
    0xFE20...0xFE2F, 0x1F3FB...0x1F3FF, 0xE0100...0xE01EF,
]

private let wideRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0,
    0x23F3...0x23F3, 0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
    0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
    0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5,
    0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
    0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
    0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55,
    0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
    0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
    0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18AFF, 0x1B000...0x1B2FF,
    0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
    0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF,
    0x20000...0x2FFFD, 0x30000...0x3FFFD,
]

func charWidth(_ v: UInt32) -> Int {
    if v < 0x300 { return 1 }
    for r in zeroWidthRanges where r.contains(v) { return 0 }
    for r in wideRanges where r.contains(v) { return 2 }
    return 1
}

import Foundation
import Darwin

/// A pseudo-terminal running the user's login shell.
final class PTY {
    let master: Int32
    let pid: pid_t
    let shellPath: String

    var onData: ((UnsafeRawBufferPointer) -> Void)?
    var onExit: (() -> Void)?

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSuspended = true
    private var pendingWrite: [UInt8] = []
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)
    private var exited = false

    init(cols: Int, rows: Int, cwd: String?) throws {
        let shell = PTY.loginShell()
        shellPath = shell
        let name = (shell as NSString).lastPathComponent

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ghosty"
        env["TERM_PROGRAM_VERSION"] = "1.0"
        env["SHELL"] = shell
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "TERMINFO", "TERMCAP", "COLUMNS", "LINES"] {
            env.removeValue(forKey: key)
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        let directory = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Everything the child touches is allocated before fork().
        let argv = PTY.cArray(["-" + name])
        let envp = PTY.cArray(env.map { "\($0.key)=\($0.value)" })
        let cShell = strdup(shell)
        let cDir = strdup(directory)
        defer {
            PTY.freeCArray(argv); PTY.freeCArray(envp)
            free(cShell); free(cDir)
        }

        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &win)
        if child < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if child == 0 {
            chdir(cDir)
            execve(cShell, argv, envp)
            _exit(127)
        }

        master = fd
        pid = child

        var t = termios()
        if tcgetattr(fd, &t) == 0 {
            t.c_iflag |= tcflag_t(IUTF8)
            tcsetattr(fd, TCSANOW, &t)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { close(fd) }
        rs.resume()
        readSource = rs

        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        ws.setEventHandler { [weak self] in self?.flush() }
        writeSource = ws
    }

    deinit {
        terminate()
    }

    private func readAvailable() {
        let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
        if n > 0 {
            buffer.withUnsafeBytes { onData?(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            handleExit()
        }
    }

    private func handleExit() {
        guard !exited else { return }
        exited = true
        readSource?.cancel()
        if writeSuspended { writeSource?.resume(); writeSuspended = false }
        writeSource?.cancel()
        let child = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        onExit?()
    }

    func write(_ bytes: [UInt8]) {
        guard !exited, !bytes.isEmpty else { return }
        pendingWrite.append(contentsOf: bytes)
        flush()
    }

    func write(_ string: String) { write(Array(string.utf8)) }

    private func flush() {
        while !pendingWrite.isEmpty {
            let n = pendingWrite.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                pendingWrite.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        // Only watch for writability while there is a backlog.
        if pendingWrite.isEmpty {
            if !writeSuspended { writeSource?.suspend(); writeSuspended = true }
        } else if writeSuspended {
            writeSource?.resume(); writeSuspended = false
        }
    }

    func resize(cols: Int, rows: Int, width: CGFloat, height: CGFloat) {
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                          ws_xpixel: UInt16(clamping: Int(width)), ws_ypixel: UInt16(clamping: Int(height)))
        _ = ioctl(master, TIOCSWINSZ, &win)
    }

    func terminate() {
        guard !exited else { return }
        onExit = nil
        kill(pid, SIGHUP)
        handleExit()
    }

    // MARK: Process introspection

    /// Name of the process group currently in the foreground (e.g. "vim"), or nil.
    var foregroundProcessName: String? {
        let pgid = tcgetpgrp(master)
        guard pgid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pgid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        // proc_name fails for processes we don't own (setuid tools like top); sysctl doesn't.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pgid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// The working directory of the foreground process (falls back to the shell).
    var currentDirectory: String? {
        let pgid = tcgetpgrp(master)
        return PTY.directory(of: pgid > 0 ? pgid : pid) ?? PTY.directory(of: pid)
    }

    private static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    // MARK: Helpers

    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func cArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() { p[i] = strdup(s) }
        p[strings.count] = nil
        return p
    }

    private static func freeCArray(_ p: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let s = p[i] { free(s); i += 1 }
        p.deallocate()
    }
}

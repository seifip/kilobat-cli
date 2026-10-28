import Foundation
import Darwin

/// Full-screen terminal sessions: single keypresses, an alternate screen and
/// flicker-free redraws. The terminal is restored on exit, Ctrl+C or SIGTERM.
enum Terminal {
    nonisolated(unsafe) private static var saved = termios()
    nonisolated(unsafe) private static var active = false
    nonisolated(unsafe) private static var inputFlags: Int32 = -1
    nonisolated(unsafe) private static var resized = false

    enum Key: Equatable { case up, down, left, right, enter, escape, tab, backspace, char(Character) }

    static var interactive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }
    /// Output is going to a pipe or file, so commands default to machine-readable JSON.
    static var piped: Bool { isatty(STDOUT_FILENO) == 0 }
    static var color: Bool { isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil }

    static func paint(_ text: String, _ code: String) -> String { color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text }
    static func violet(_ text: String) -> String { paint(text, "38;2;176;150;250") }
    static func blue(_ text: String) -> String { paint(text, "38;2;102;179;250") }
    static func green(_ text: String) -> String { paint(text, "38;2;110;231;168") }
    static func rose(_ text: String) -> String { paint(text, "38;2;255;122;150") }
    static func dim(_ text: String) -> String { paint(text, "2") }
    static func bold(_ text: String) -> String { paint(text, "1") }
    static func selected(_ text: String) -> String { paint(text, "1;38;2;20;18;28;48;2;176;150;250") }

    static func enter() {
        guard !active, interactive else { return }
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        active = true
        // Autowrap off: lines wider than the window are cut instead of wrapping and scrolling.
        emit("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?7l\u{1b}[H\u{1b}[2J")
        signal(SIGINT) { _ in Terminal.leave(); exit(130) }
        signal(SIGTERM) { _ in Terminal.leave(); exit(143) }
        signal(SIGWINCH) { _ in Terminal.resized = true }
    }

    static func leave() {
        guard active else { return }
        active = false
        signal(SIGWINCH, SIG_DFL)
        emit("\u{1b}[?7h\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }

    /// Non-blocking stdin for line-mode watch screens, restored by `restoreInput`, Ctrl+C or SIGTERM.
    static func nonblockingInput() {
        guard inputFlags < 0 else { return }
        inputFlags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK)
        signal(SIGINT) { _ in Terminal.restoreInput(); exit(130) }
        signal(SIGTERM) { _ in Terminal.restoreInput(); exit(143) }
    }

    static func restoreInput() {
        guard inputFlags >= 0 else { return }
        _ = fcntl(STDIN_FILENO, F_SETFL, inputFlags)
        inputFlags = -1
    }

    /// Repaints in place: home the cursor, overwrite each line, clear what is left. Rows past the window are dropped.
    static func draw(_ lines: [String]) {
        emit("\u{1b}[H" + lines.prefix(height).map { $0 + "\u{1b}[K" }.joined(separator: "\n") + "\u{1b}[J")
    }

    /// Returns a pending keypress without blocking. Reads one key at a time, so
    /// fast typing or a paste arrives as separate keys instead of being dropped.
    static func key() -> Key? {
        guard ready(0), let first = byte() else { return nil }
        switch first {
        case 27:
            guard ready(15), let introducer = byte(), introducer == 91 || introducer == 79, let final = byte() else { return .escape }
            return [65: .up, 66: .down, 67: .right, 68: .left][final]
        case 10, 13: return .enter
        case 9: return .tab
        case 127, 8: return .backspace
        default:
            // UTF-8: the lead byte says how many continuation bytes follow.
            let extra = first >= 0xF0 ? 3 : first >= 0xE0 ? 2 : first >= 0xC0 ? 1 : 0
            var bytes = [first]
            for _ in 0..<extra { if let next = byte() { bytes.append(next) } }
            return String(bytes: bytes, encoding: .utf8)?.first.map(Key.char)
        }
    }

    private static func ready(_ milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0
    }

    private static func byte() -> UInt8? {
        var value: UInt8 = 0
        return read(STDIN_FILENO, &value, 1) == 1 ? value : nil
    }

    /// Waits up to `seconds` for a keypress while letting other main-actor work run.
    @MainActor static func waitForKey(_ seconds: Double) async -> Key? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let key = key() { return key }
            if resized { resized = false; return nil }
            try? await Task.sleep(for: .milliseconds(40))
        } while Date() < deadline
        return nil
    }

    static var width: Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }
    static var height: Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_row > 0 ? Int(size.ws_row) : 24
    }

    private static func emit(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }
}

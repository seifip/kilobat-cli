import Foundation
import AppKit
import Observation

public enum NetworkTools {
    @discardableResult static func administrator(_ command: String) async throws -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await CommandRunner.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 120)
        guard result.status == 0 else { throw DiagnosticError(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.output
    }
    public static func flushDNS() async throws {
        _ = try await administrator("/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
    }
}

/// A temporary experiment, never persisted or automatically enabled.
/// A privileged watchdog owns restoration even if the GUI exits unexpectedly.
@MainActor @Observable public final class LowLatencyMode {
    public private(set) var active = false
    public private(set) var busy = false
    public private(set) var expires: Date?
    public var error: String?
    private var marker: URL?
    private var watcher: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    public init() {
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.release() }
        })
    }
    private func isUp() async -> Bool? {
        let result = await CommandRunner.run("/sbin/ifconfig", ["awdl0"])
        guard result.status == 0, let flags = result.output.split(separator: "\n").first else { return nil }
        return flags.contains("<UP,") || flags.contains(",UP,")
    }
    public func enable() async {
        guard !busy, !active else { return }
        busy = true; defer { busy = false }
        guard await isUp() == true else { error = "AWDL is unavailable or already paused. Kilobat has not changed it."; return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-awdl-\(UUID().uuidString)")
        do {
            try Data().write(to: file, options: .atomic)
            marker = file
            // Root only reads the lease; it never writes to a user-controlled path.
            // Exit, expiry, lease removal, or a default-route change restores AWDL.
            let lease = DNSService.shellQuote(file.path)
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            trap '/sbin/ifconfig awdl0 up' EXIT HUP INT TERM
            route=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:|interface:/ {print $2}')
            /sbin/ifconfig awdl0 down || exit 1
            i=0
            while [ "$i" -lt 450 ] && [ -f \(lease) ] && /bin/kill -0 \(pid) 2>/dev/null; do
              /bin/sleep 2
              current=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:|interface:/ {print $2}')
              [ "$current" = "$route" ] || break
              i=$((i+1))
            done
            """
            let command = "/usr/bin/nohup /bin/sh -c " + DNSService.shellQuote(script) + " </dev/null >/dev/null 2>&1 &"
            try await NetworkTools.administrator(command)
            try await Task.sleep(for: .seconds(1))
            guard await isUp() == false else { throw DiagnosticError("AWDL did not pause. No low-latency mode is active.") }
            active = true; expires = Date().addingTimeInterval(900)
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    if await self.isUp() == true { self.release(); self.active = false; self.expires = nil; return }
                }
            }
        } catch { release(); self.error = error.localizedDescription }
    }
    public func release() {
        if let marker { try? FileManager.default.removeItem(at: marker) }
        marker = nil
    }
    public func disable() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        release()
        try? await Task.sleep(for: .seconds(3))
        guard await isUp() == true else { error = "AWDL has not restored yet. Retry Restore AWDL; macOS may ask for administrator approval."; return }
        active = false; expires = nil; watcher?.cancel()
    }
    public func restore() async {
        do { try await NetworkTools.administrator("/sbin/ifconfig awdl0 up"); await disable() }
        catch { self.error = error.localizedDescription }
    }
}

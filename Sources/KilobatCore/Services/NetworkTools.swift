import Foundation
import AppKit
import Observation

public enum NetworkTools {
    @discardableResult static func administrator(_ command: String, prompt: String? = nil) async throws -> String {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let result = await CommandRunner.run("/usr/bin/osascript", ["-e", "do shell script \(quoted(command))\(prompt.map { " with prompt " + quoted($0) } ?? "") with administrator privileges"], timeout: 120)
        guard result.status == 0 else { throw DiagnosticError(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.output
    }
    public static func flushDNS() async throws {
        _ = try await administrator("/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
    }
}

/// One AWDL pause: how long it may last and what ends it. Pure, so the restore rules are testable.
public struct LowLatencyHold: Codable, Sendable, Equatable {
    public static let longest: TimeInterval = 4 * 3600
    public static let lengths: [(title: String, seconds: TimeInterval)] = [(String(localized: "15 minutes"), 900), (String(localized: "1 hour"), 3600), (String(localized: "2 hours"), 7200)]
    public let started: Date
    public let expires: Date
    public let appPID: Int32?
    public let appName: String?
    /// The process that asked; a restore marker it leaves behind matters only once it is gone.
    public let ownerPID: Int32
    public init(started: Date = Date(), seconds: TimeInterval?, app: (pid: Int32, name: String)? = nil, owner: Int32 = getpid()) {
        self.started = started
        expires = started.addingTimeInterval(min(max(seconds ?? Self.longest, 1), Self.longest))
        appPID = app?.pid; appName = app?.name; ownerPID = owner
    }
    public enum Ending: String, Sendable { case expired, appQuit }
    public func ending(now: Date, appRunning: Bool) -> Ending? {
        if now >= expires { return .expired }
        if appPID != nil && !appRunning { return .appQuit }
        return nil
    }
    /// Two-second watchdog ticks before the hard limit.
    public var ticks: Int { Int((expires.timeIntervalSince(started) / 2).rounded(.up)) }
    public func label(now: Date = Date()) -> String {
        if let appName { return String(localized: "until \(appName) quits") }
        let minutes = Int((expires.timeIntervalSince(now) / 60).rounded(.up))
        return minutes >= 60 ? String(localized: "\(minutes / 60) h \(minutes % 60) min left") : String(localized: "\(max(1, minutes)) min left")
    }
    /// "15m", "1h", "2h" or "90m"; nil above four hours.
    public static func seconds(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let value = Double(text.dropLast()), value > 0 else { return nil }
        let seconds = switch unit { case "m": value * 60; case "h": value * 3600; default: -1.0 }
        return seconds > 0 && seconds <= longest ? seconds : nil
    }

    public enum Recovery: Equatable, Sendable { case none, clear, restore }
    /// After a crash: restore only when the pause outlived whoever started it.
    public static func recovery(marker: LowLatencyHold?, awdlUp: Bool?, ownerAlive: Bool) -> Recovery {
        guard marker != nil, !ownerAlive else { return .none }
        return awdlUp == false ? .restore : .clear
    }
    static var markerURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/low-latency.json") }
    static func loadMarker() -> LowLatencyHold? { (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
    func saveMarker() {
        try? FileManager.default.createDirectory(at: Self.markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.markerURL, options: .atomic)
    }
    static func clearMarker() { try? FileManager.default.removeItem(at: markerURL) }
    public static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

/// A temporary experiment, never automatically enabled. A privileged watchdog owns restoration
/// even if the GUI exits unexpectedly; a marker covers the watchdog itself being killed.
@MainActor @Observable public final class LowLatencyMode {
    public private(set) var active = false
    public private(set) var busy = false
    public private(set) var hold: LowLatencyHold?
    public var expires: Date? { hold?.expires }
    public var error: String?
    private var marker: URL?
    private var watcher: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var recovered = false
    public init() {
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.release() }
        })
    }
    /// Apps a pause can be tied to.
    public static func runningApps() -> [(pid: Int32, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.localizedName != nil }
            .map { ($0.processIdentifier, $0.localizedName!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public static func isUp() async -> Bool? {
        let result = await CommandRunner.run("/sbin/ifconfig", ["awdl0"])
        guard result.status == 0 else { return nil }
        return NearbyRadios.parseInterface(result.output)?.up
    }
    public func enable(seconds: TimeInterval? = 900, app: (pid: Int32, name: String)? = nil) async {
        guard !busy, !active else { return }
        busy = true; defer { busy = false }
        guard await Self.isUp() == true else { error = String(localized: "AWDL is unavailable or already paused. Kilobat has not changed it."); return }
        let hold = LowLatencyHold(seconds: seconds, app: app)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-awdl-\(UUID().uuidString)")
        do {
            try Data().write(to: file, options: .atomic)
            marker = file
            // Root only reads the lease; it never writes to a user-controlled path.
            // Exit, expiry, lease removal, the chosen app quitting or a default-route change restores AWDL.
            let lease = DNSService.shellQuote(file.path)
            let pid = ProcessInfo.processInfo.processIdentifier
            let tied = hold.appPID.map { " && /bin/kill -0 \($0) 2>/dev/null" } ?? ""
            let script = """
            trap '/sbin/ifconfig awdl0 up' EXIT HUP INT TERM
            route=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:|interface:/ {print $2}')
            /sbin/ifconfig awdl0 down || exit 1
            i=0
            while [ "$i" -lt \(hold.ticks) ] && [ -f \(lease) ] && /bin/kill -0 \(pid) 2>/dev/null\(tied); do
              /bin/sleep 2
              current=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:|interface:/ {print $2}')
              [ "$current" = "$route" ] || break
              # macOS brings AWDL back for AirDrop, Handoff or after sleep; keep it paused for as long as the hold lasts.
              /sbin/ifconfig awdl0 2>/dev/null | /usr/bin/grep -q '<UP' && /sbin/ifconfig awdl0 down
              i=$((i+1))
            done
            """
            let command = "/usr/bin/nohup /bin/sh -c " + DNSService.shellQuote(script) + " </dev/null >/dev/null 2>&1 &"
            hold.saveMarker()
            try await NetworkTools.administrator(command)
            try await Task.sleep(for: .seconds(1))
            guard await Self.isUp() == false else { throw DiagnosticError(String(localized: "AWDL did not pause. No low-latency mode is active.")) }
            active = true; self.hold = hold
            watcher = Task { [weak self] in
                var up = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    // The root loop pauses AWDL again within two seconds, so only a link that stays up means the pause ended.
                    up = await Self.isUp() == true ? up + 1 : 0
                    if up >= 3 { self.finish(); return }
                    if let hold = self.hold, hold.ending(now: Date(), appRunning: hold.appPID.map(LowLatencyHold.alive) ?? true) != nil { self.release() }
                }
            }
        } catch {
            release(); self.error = error.localizedDescription
            if await Self.isUp() != false { LowLatencyHold.clearMarker() }
        }
    }
    private func finish() {
        release(); active = false; hold = nil; watcher?.cancel()
        LowLatencyHold.clearMarker()
    }
    public func release() {
        if let marker { try? FileManager.default.removeItem(at: marker) }
        marker = nil
    }
    /// Ends every pause this user started, including one another Kilobat process such as the CLI holds.
    public static func releaseAll() -> Int {
        let directory = FileManager.default.temporaryDirectory
        let leases = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("kilobat-awdl-") }
        for file in leases { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        return leases.count
    }
    public func disable() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        release()
        try? await Task.sleep(for: .seconds(3))
        guard await Self.isUp() == true else { error = String(localized: "AWDL has not restored yet. Retry Restore AWDL; macOS may ask for administrator approval."); return }
        finish()
    }
    public func restore() async {
        do { try await NetworkTools.administrator("/sbin/ifconfig awdl0 up"); await disable() }
        catch { self.error = error.localizedDescription }
    }
    /// Turns AWDL back on with an administrator prompt, for a pause nothing is watching any more.
    public static func forceRestore(reason: String) async throws {
        try await NetworkTools.administrator("/sbin/ifconfig awdl0 up", prompt: reason)
        LowLatencyHold.clearMarker()
    }
    /// On launch: a pause whose owner and watchdog both died would otherwise leave AirDrop off.
    public func recover() async {
        guard !active, !recovered else { return }
        recovered = true
        let marker = LowLatencyHold.loadMarker()
        let alive = marker.map { $0.ownerPID != getpid() && LowLatencyHold.alive($0.ownerPID) } ?? false
        switch LowLatencyHold.recovery(marker: marker, awdlUp: await Self.isUp(), ownerAlive: alive) {
        case .none: return
        case .clear: LowLatencyHold.clearMarker()
        case .restore:
            do { try await Self.forceRestore(reason: String(localized: "Kilobat restores AirDrop (AWDL), which stayed paused after an earlier low-latency session ended unexpectedly.")) }
            catch { self.error = error.localizedDescription }
        }
    }
}

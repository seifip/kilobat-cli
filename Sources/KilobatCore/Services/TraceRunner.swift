import Foundation
import Darwin
import SystemConfiguration

/// traceroute, read as it prints, so a trace can stop once the route goes quiet instead of waiting a second for every
/// remaining hop up to the maximum.
public enum TraceRunner {
    /// Silent hops in a row after which the rest of the route is assumed silent too: mtr's own default (`--max-unknown 5`).
    public static let silentHops = 5

    /// Whether `output` (complete lines only) ends in `silentHops` hops in a row with no reply.
    public static func quiet(_ output: String) -> Bool {
        var complete = output
        if let last = complete.lastIndex(of: "\n") { complete = String(complete[...last]) } else { return false }
        let hops = RouteTrace.parse(complete)
        guard hops.count >= silentHops else { return false }
        return hops.suffix(silentHops).allSatisfy { $0.samples.isEmpty }
    }

    /// The address in traceroute's header line, "traceroute to example.com (93.184.216.34), 30 hops max".
    public static func destination(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("traceroute to ") }),
              let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { return nil }
        let address = String(line[line.index(after: open)..<close])
        return ExpertTools.isAddress(address) ? address : nil
    }

    /// Runs traceroute and returns everything it printed, stopping it after `silentHops` silent hops in a row.
    public static func run(host: String, options: TraceOptions, queries: Int) async -> CommandResult {
        guard !Task.isCancelled else { return CommandResult(output: "", status: -1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        process.arguments = options.arguments(host: host, queries: queries)
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading, fd = reader.fileDescriptor
        defer { try? reader.close() }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { return CommandResult(output: "", status: -1) }
        IdleCounters.bump("launch /usr/sbin/traceroute")
        do { try process.run() } catch { return CommandResult(output: error.localizedDescription, status: -1) }
        let clock = ContinuousClock()
        // One second a probe at most, plus slack for name resolution.
        let deadline = clock.now + .seconds(Double(options.maxHops * min(max(queries, 1), 3) + 6))
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16_384), stopped = false
        func drain() -> Bool {
            var read = false
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                output.append(contentsOf: buffer.prefix(count)); read = true
            }
            return read
        }
        while process.isRunning && !Task.isCancelled && clock.now < deadline {
            if drain(), quiet(String(decoding: output, as: UTF8.self)) { stopped = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            let grace = clock.now + .milliseconds(100)
            while process.isRunning && clock.now < grace { _ = drain(); try? await Task.sleep(for: .milliseconds(10)) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        _ = drain()
        var text = String(decoding: output, as: UTF8.self)
        if stopped {
            // Keep complete lines only, and say why the trace ends early.
            if let last = text.lastIndex(of: "\n") { text = String(text[...last]) }
            text += String(localized: "Stopped after \(silentHops) hops in a row without a reply.", comment: "traceroute output note") + "\n"
        }
        return CommandResult(output: text, status: stopped ? 0 : (process.isRunning ? -1 : process.terminationStatus))
    }
}

public extension ExpertTools {
    /// An IPv4 or IPv6 address, not a name.
    static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// One trace with `options`, as text, the probe note last.
    static func route(to host: String, queries: Int = 1, options: TraceOptions) async throws -> String {
        guard validHost(host) else { throw DiagnosticError(String(localized: "Enter a hostname or IP address, without a URL or options.")) }
        let result = await TraceRunner.run(host: host, options: options, queries: queries)
        return result.output + "\n" + String(localized: "Intermediate routers may ignore probes; * alone is not evidence of packet loss.")
    }

    /// Watches the route to `host`: one probe a hop every `interval` seconds (start to start; a round that takes longer
    /// starts the next at once, never two at a time) until `duration` passes, `stop` returns an end or the task is
    /// cancelled. Hands the watch over after every round, and returns it ended.
    static func watchRoute(host: String, label: String? = nil, options: TraceOptions = .standard, interval: Double, duration: Double?,
                           id: UUID = UUID(), stop: @escaping @MainActor () -> WatchedRoute.End? = { nil },
                           each: @escaping @MainActor (WatchedRoute) -> Void) async throws -> WatchedRoute {
        guard validHost(host) else { throw DiagnosticError(String(localized: "Enter a hostname or IP address, without a URL or options.")) }
        let interval = max(1, interval)
        var watch = WatchedRoute(id: id, host: host, label: label, started: Date(), interval: interval, duration: duration, options: options)
        var failures = 0
        // Wall time runs on through sleep while the suspending clock stops: a gap between them means the Mac slept,
        // even where nothing delivers a sleep notification (the command line).
        let wall = Date(), awake = SuspendingClock.now, network = NetworkFingerprint.current()
        func slept() -> Bool {
            let elapsed = SuspendingClock.now - awake
            return Date().timeIntervalSince(wall) - (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) > 10
        }
        func ended() async -> WatchedRoute.End? {
            if let end = await stop() { return end }
            return slept() ? .slept : nil
        }
        while true {
            let began = Date()
            if Task.isCancelled { watch.end = .stopped; break }
            if let end = await ended() { watch.end = end; break }
            if let duration, began.timeIntervalSince(watch.started) >= duration { watch.end = .finished; break }
            let result = await TraceRunner.run(host: host, options: options, queries: 1)
            if Task.isCancelled { watch.end = .stopped; break }
            // A round cut short by sleep or a network change describes neither path.
            if let end = await ended() { watch.end = end; break }
            if NetworkFingerprint.current() != network { watch.end = .networkChanged; break }
            let hops = RouteTrace.parse(result.output)
            if watch.address == nil { watch.address = TraceRunner.destination(result.output) ?? (isAddress(host) ? host : nil) }
            if hops.isEmpty {
                failures += 1
                if failures >= 3 && watch.rounds.isEmpty { watch.end = .failed; break }
            } else {
                failures = 0
                watch.append(hops, at: began)
            }
            await each(watch)
            let wait = interval - Date().timeIntervalSince(began)
            if wait > 0 {
                // Short naps, so Stop and a duration's end are noticed within a quarter second.
                let until = Date().addingTimeInterval(wait)
                while Date() < until {
                    if Task.isCancelled { break }
                    if let duration, Date().timeIntervalSince(watch.started) >= duration { break }
                    if await ended() != nil { break }
                    try? await Task.sleep(for: .milliseconds(min(250, max(10, until.timeIntervalSinceNow * 1000))))
                }
            }
        }
        watch.ended = Date()
        if watch.end == nil { watch.end = .stopped }
        await each(watch)
        return watch
    }
}

/// The default route's interface and router, to tell when a watch has moved to another network.
public struct NetworkFingerprint: Equatable, Sendable {
    public let interface: String?
    public let router: String?
    public static func current() -> NetworkFingerprint {
        guard let store = SCDynamicStoreCreate(nil, "Kilobat route watch" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return NetworkFingerprint(interface: nil, router: nil)
        }
        return NetworkFingerprint(interface: value["PrimaryInterface"] as? String, router: value["Router"] as? String)
    }
}

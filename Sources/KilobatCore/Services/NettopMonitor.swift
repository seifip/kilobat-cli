import Foundation

/// Reads Apple's network statistics. No packet capture, root access, or private APIs.
public final class NettopMonitor: @unchecked Sendable {
    private var task: Process?
    private let queue = DispatchQueue(label: "co.seifi.kilobat.nettop", qos: .utility)
    private let lock = NSLock()
    private var generation = UUID()
    private func current(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == id }
    public init() {}

    public static func parseRow(_ line: String) -> ProcessTraffic? {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 3,
              let dot = columns[0].lastIndex(of: "."),
              let pid = Int32(columns[0][columns[0].index(after: dot)...]),
              let received = UInt64(columns[1]), let sent = UInt64(columns[2]) else { return nil }
        return ProcessTraffic(pid: pid, process: String(columns[0][..<dot]), received: received, sent: sent)
    }

    /// With the interface column, a process row (`name.pid,,in,out,`) is followed by its connections
    /// (`tcp4 local<->remote,en0,in,out,`), which say whether its bytes went to the Internet, the local network or a tunnel.
    /// `orphaned` is set by a row that is neither a connection nor a readable process (a name with a comma shifts the
    /// columns): the connections after it belong to that process, not to the one before, so they are dropped.
    static func parse(_ line: String, into rows: inout [ProcessTraffic], orphaned: inout Bool) {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 4 else { return }
        let counters = UInt64(columns[2]).flatMap { received in UInt64(columns[3]).map { (received, $0) } }
        if columns[0].contains("<->") {
            guard !orphaned, !rows.isEmpty, let (received, sent) = counters else { return }
            rows[rows.count - 1].connections.append(ConnectionTraffic(id: String(columns[0]), route: TrafficRoute.classify(columns[0], interface: columns[1]),
                                                                    interface: String(columns[1]), received: received, sent: sent))
        } else if let (received, sent) = counters, let dot = columns[0].lastIndex(of: "."), let pid = Int32(columns[0][columns[0].index(after: dot)...]) {
            rows.append(ProcessTraffic(pid: pid, process: String(columns[0][..<dot]), received: received, sent: sent))
            orphaned = false
        } else {
            orphaned = true
        }
    }

    public func start(scope: String = "external", onSample: @escaping @Sendable (TrafficSnapshot) -> Void,
               onError: @escaping @Sendable (String) -> Void) {
        stop()
        let id = UUID()
        lock.withLock { generation = id }
        launch(id, scope: scope, failures: 0, onSample: onSample, onError: onError)
    }

    /// nettop can exit on its own (sleep, interface churn). Relaunch while this generation is current,
    /// backing off up to a minute when launches keep failing without producing samples.
    private func launch(_ id: UUID, scope: String, failures: Int, onSample: @escaping @Sendable (TrafficSnapshot) -> Void,
                        onError: @escaping @Sendable (String) -> Void) {
        let process = Process()
        // A PTY keeps nettop line-buffered; direct pipes coalesce samples and distort rates.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // Per-connection rows rather than -P: about 1.7% of a core instead of 1%, and the only way to tell
        // Internet bytes from LAN, AirDrop and VPN tunnel bytes.
        process.arguments = ["-q", "-F", "/dev/null", "/usr/bin/nettop", "-L", "0", "-s", "1", "-n", "-x", "-J", "interface,bytes_in,bytes_out", "-t", ["external", "wifi", "wired"].contains(scope) ? scope : "external"]
        let output = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let retry: @Sendable (Bool) -> Void = { [weak self] sampled in
            guard let self, self.current(id) else { return }
            let next = sampled ? 0 : failures + 1
            if next == 3 { onError(String(localized: "Network monitoring stopped. Retrying…")) }
            self.queue.asyncAfter(deadline: .now() + min(60, pow(2, Double(next)))) { [weak self] in
                self?.launch(id, scope: scope, failures: next, onSample: onSample, onError: onError)
            }
        }
        lock.lock()
        guard generation == id else { lock.unlock(); return }
        task = process
        do { try process.run() } catch {
            task = nil; lock.unlock(); if failures == 0 { onError(error.localizedDescription) }; retry(false); return
        }
        lock.unlock()
        // Every launch owns its parser state. A stopped reader cannot leak rows into
        // a new interface scope or publish an error after intentional cancellation.
        queue.async { [weak self] in
            guard let self else { return }
            var pending = Data(), rows: [ProcessTraffic] = [], orphaned = false, sawHeader = false, sampled = false
            reading: while process.isRunning && self.current(id) {
                // This block runs as long as nettop does, so without its own pool every autoreleased chunk stays
                // in memory for good.
                let more: Bool = autoreleasepool {
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty, self.current(id) else { return false }
                    pending.append(data)
                    // Bytes, not Characters, and one trim at the end: a second's output can be thousands of lines.
                    var start = pending.startIndex
                    while let newline = pending[start...].firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[start..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        start = pending.index(after: newline)
                        if line.contains(",bytes_in,bytes_out,") {
                            if sawHeader && self.current(id) { onSample(TrafficSnapshot(timestamp: Date(), processes: rows)); sampled = true }
                            rows = []; orphaned = false; sawHeader = true
                        } else { Self.parse(line, into: &rows, orphaned: &orphaned) }
                    }
                    pending = Data(pending[start...])
                    return true
                }
                if !more { break reading }
            }
            process.waitUntilExit()
            retry(sampled)
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
        if let task, task.isRunning { task.terminate() }
        task = nil
    }

    deinit { stop() }
}

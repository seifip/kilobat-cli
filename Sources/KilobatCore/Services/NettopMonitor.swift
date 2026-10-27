import Foundation

/// Reads Apple's network statistics. No packet capture, root access, or private APIs.
public final class NettopMonitor: @unchecked Sendable {
    private var task: Process?
    private let queue = DispatchQueue(label: "co.seifi.kilobat.nettop", qos: .utility)
    private let lock = NSLock()
    private var generation = UUID()
    private func current(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == id }

    public static func parseRow(_ line: String) -> ProcessTraffic? {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 3,
              let dot = columns[0].lastIndex(of: "."),
              let pid = Int32(columns[0][columns[0].index(after: dot)...]),
              let received = UInt64(columns[1]), let sent = UInt64(columns[2]) else { return nil }
        return ProcessTraffic(pid: pid, process: String(columns[0][..<dot]), received: received, sent: sent)
    }

    public func start(scope: String = "external", onSample: @escaping @Sendable (TrafficSnapshot) -> Void,
               onError: @escaping @Sendable (String) -> Void) {
        stop()
        let process = Process()
        // A PTY keeps nettop line-buffered; direct pipes coalesce samples and distort rates.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "-F", "/dev/null", "/usr/bin/nettop", "-P", "-L", "0", "-s", "1", "-n", "-x", "-J", "bytes_in,bytes_out", "-t", ["external", "wifi", "wired"].contains(scope) ? scope : "external"]
        let output = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let id = UUID()
        lock.lock()
        generation = id
        task = process
        do { try process.run() } catch {
            task = nil; lock.unlock(); onError(error.localizedDescription); return
        }
        lock.unlock()
        // Every launch owns its parser state. A stopped reader cannot leak rows into
        // a new interface scope or publish an error after intentional cancellation.
        queue.async { [weak self] in
            guard let self else { return }
            var buffer = "", rows: [ProcessTraffic] = [], sawHeader = false
            while process.isRunning && self.current(id) {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty, self.current(id) else { break }
                buffer += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer.removeSubrange(...newline)
                    if line.contains(",bytes_in,bytes_out,") {
                        if sawHeader && self.current(id) { onSample(TrafficSnapshot(timestamp: Date(), processes: rows)) }
                        rows = []; sawHeader = true
                    } else if let row = Self.parseRow(line) { rows.append(row) }
                }
            }
            process.waitUntilExit()
            if self.current(id) && process.terminationStatus != 0 { onError("Network monitoring stopped. Reopen Kilobat to reconnect.") }
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

import Foundation
import Observation

/// Mounted network shares and whether their servers still answer, checked with Health's checks. A share counts as
/// gone after two checks in a row without an answer, so a moment's hiccup isn't an alarm. It never opens or stats a
/// share; it unmounts one only when the person presses Eject on its finding.
@MainActor @Observable public final class ShareWatch {
    /// The latest check of every mounted share.
    public private(set) var checks: [ShareCheck] = []
    public private(set) var checking = false
    /// The share being ejected, by id.
    public private(set) var ejecting: String?
    /// Shares a plain eject couldn't let go of: their finding offers Force Eject.
    public private(set) var needsForce: Set<String> = []
    /// Shares whose server has stopped answering, or turns connections away, on two checks in a row.
    public var gone: [ShareCheck] { checks.filter { $0.finding != nil && (misses[$0.id] ?? 0) >= Self.confirm } }
    public static let confirm = 2
    /// A share went away or came back: for History and an alert.
    @ObservationIgnored public var onChange: ((_ check: ShareCheck, _ gone: Bool) -> Void)?

    @ObservationIgnored var probe: () async -> [ShareCheck] = { await ShareProbe.checkAll() }
    @ObservationIgnored var misses: [String: Int] = [:]
    @ObservationIgnored private var last = Date.distantPast
    /// Screenshots: a preview stays put.
    @ObservationIgnored private var frozen = false

    public init() {}

    /// At most every 45 seconds unless forced; with no network share mounted it costs one read of the mount table.
    public func refresh(force: Bool = false, now: Date = Date()) async {
        guard !checking, !frozen, force || now.timeIntervalSince(last) >= 45 else { return }
        checking = true; last = now
        let latest = await probe()
        apply(latest)
        checking = false
    }

    /// Ejects a share with `diskutil unmount`, or `unmount force` once a plain eject failed, off the main thread and
    /// given up on after 20 seconds, so a dead server can't hold Kilobat. Checks again right after, which clears the
    /// finding when the share is gone from the mount table. True when it was ejected.
    @discardableResult public func eject(_ check: ShareCheck) async -> Bool {
        guard ejecting == nil else { return false }
        ejecting = check.id
        let force = needsForce.contains(check.id)
        let ok = await Self.unmount(check.share.mountPoint, force: force)
        if ok { needsForce.remove(check.id) } else { needsForce.insert(check.id) }
        ejecting = nil
        await refresh(force: true)
        return ok
    }

    nonisolated static func unmount(_ mountPoint: String, force: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                process.arguments = force ? ["unmount", "force", mountPoint] : ["unmount", mountPoint]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: false); return }
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                if done.wait(timeout: .now() + 20) == .timedOut { process.terminate(); continuation.resume(returning: false); return }
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    func apply(_ latest: [ShareCheck]) {
        var counts: [String: Int] = [:]
        for check in latest {
            let before = misses[check.id] ?? 0
            switch check.state {
            case .silent, .refused:
                counts[check.id] = before + 1
                if before + 1 == Self.confirm { onChange?(check, true) }
            case .unknown:
                // Can't tell: keep the count as it was.
                counts[check.id] = before
            case .answering:
                if before >= Self.confirm { onChange?(check, false) }
            }
        }
        // An ejected share drops out of the table, and with it, out of the count.
        misses = counts
        needsForce = needsForce.filter { id in latest.contains { $0.id == id && $0.state != .answering } }
        checks = latest
    }

    #if DEBUG
    /// Screenshots: shares shown as if each had been checked twice.
    public func preview(_ sample: [ShareCheck]) {
        frozen = true; checks = sample
        misses = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0.finding == nil ? 0 : Self.confirm) })
    }
    #endif
}

/// This Mac's Ethernet ports, read with Health's checks at most every 30 seconds.
@MainActor @Observable public final class WiredWatch {
    public private(set) var report: WiredReport?
    public private(set) var reading = false
    /// The findings to show. "No address" waits until it has lasted 20 seconds: DHCP takes a few after plugging in.
    public var findings: [WiredReport.Finding] {
        guard let report else { return [] }
        return report.findings.filter { finding in
            guard finding.kind == .noAddress, let interface = finding.interface else { return true }
            return noAddressSince[interface].map { report.date.timeIntervalSince($0) >= 20 } ?? false
        }
    }
    @ObservationIgnored var probe: () async -> WiredReport = { await WiredProbe.read() }
    @ObservationIgnored private var noAddressSince: [String: Date] = [:]
    @ObservationIgnored private var last = Date.distantPast
    @ObservationIgnored private var frozen = false

    public init() {}

    public func refresh(force: Bool = false, now: Date = Date()) async {
        guard !reading, !frozen, force || now.timeIntervalSince(last) >= 30 else { return }
        reading = true; last = now
        apply(await probe())
        reading = false
    }

    func apply(_ latest: WiredReport) {
        let stuck = Set(latest.findings.filter { $0.kind == .noAddress }.compactMap(\.interface))
        noAddressSince = noAddressSince.filter { stuck.contains($0.key) }
        for interface in stuck where noAddressSince[interface] == nil { noAddressSince[interface] = latest.date }
        report = latest
    }

    #if DEBUG
    public func preview(_ sample: WiredReport) {
        frozen = true; report = sample
        noAddressSince = Dictionary(uniqueKeysWithValues: sample.findings.filter { $0.kind == .noAddress }.compactMap(\.interface).map { ($0, .distantPast) })
    }
    #endif
}

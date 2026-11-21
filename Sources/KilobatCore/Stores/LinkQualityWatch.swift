import Foundation
import Observation

/// Live link quality to one local device: a ping a second (the same stream calls use), read as the last minute's round
/// trip, jitter and loss, with one alert when the last 15 seconds turn poor after a better minute.
@MainActor @Observable public final class LinkQualityWatch {
    public struct Target: Equatable, Sendable { public let address: String; public let name: String
        public init(address: String, name: String) { self.address = address; self.name = name } }
    public private(set) var target: Target?
    public private(set) var pings: [CallSamples.Ping] = []
    /// Seconds since the stream started, at the last read.
    public private(set) var now: Double = 0
    public private(set) var degraded = false
    /// Called when the link turns poor, at most every five minutes.
    @ObservationIgnored public var onDegraded: ((Target, LinkReading) -> Void)?
    @ObservationIgnored private var stream: PingStream?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastAlert: Date?
    public static let alertGap: TimeInterval = 300

    public init() {}

    #if DEBUG
    /// Made-up pings for screenshots; debug builds only.
    public func preview(_ target: Target, pings: [CallSamples.Ping], now: Double) {
        self.target = target; self.pings = pings; self.now = now; degraded = LinkQuality.degraded(pings, now: now)
    }
    #endif

    public var reading: LinkReading { LinkQuality.reading(pings, since: now - LinkQuality.window) }
    public var line: [Double?] { LinkQuality.line(pings, now: now) }

    /// Starts watching `address`, or keeps watching it; another address starts over.
    public func watch(_ address: String, name: String) {
        if target?.address == address { target = Target(address: address, name: name); return }
        stop()
        guard PortScan.ipv4(address) != nil else { return }
        target = Target(address: address, name: name)
        let start = Date(), stream = PingStream.address(address, start: start)
        self.stream = stream
        task = Task { [weak self] in
            await stream.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let pings = await stream.current()
                self.update(pings.suffix(600), now: Date().timeIntervalSince(start))
            }
        }
    }

    public func stop() {
        task?.cancel(); task = nil
        if let stream { Task { await stream.stop() } }
        stream = nil; target = nil; pings = []; now = 0; degraded = false
    }

    private func update(_ pings: ArraySlice<CallSamples.Ping>, now: Double) {
        self.pings = Array(pings); self.now = now
        let poor = LinkQuality.degraded(self.pings, now: now)
        if poor, !degraded, let target, lastAlert.map({ Date().timeIntervalSince($0) >= Self.alertGap }) ?? true {
            lastAlert = Date()
            onDegraded?(target, LinkQuality.reading(self.pings, since: now - LinkQuality.recent))
        }
        // Stays marked until a whole recent stretch is better again.
        if poor { degraded = true } else if LinkQuality.reading(self.pings, since: now - LinkQuality.recent).grade != .poor { degraded = false }
    }
}

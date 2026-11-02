import Foundation

/// What each device on the home network sent and received over a stretch of time, from a router integration's
/// per-device counters. Kilobat can't see other devices' traffic from the Mac; this is the hook such an integration
/// fills only with internet-qualified per-client byte counts, summed over the stretch. FRITZ!Box TR-064
/// exposes whole-home counters, not per-client traffic, and cannot fill this hook.
public struct DeviceUsageWindow: Sendable, Equatable {
    public struct Device: Sendable, Equatable {
        public let mac: String
        public let sent: UInt64
        public let received: UInt64
        public init(mac: String, sent: UInt64, received: UInt64) { self.mac = MACAddress.normalized(mac) ?? mac.lowercased(); self.sent = sent; self.received = received }
    }
    public let start: Date
    public let end: Date
    public let devices: [Device]
    /// What the whole home sent to the internet over the stretch, from the router's internet counters; nil when the
    /// router reports only per-device numbers. A partial client list is never a whole-home total.
    public let totalSent: UInt64?
    /// The router or integration it came from, such as OpenWrt nlbwmon: named so a number is never mistaken for Kilobat's own.
    public let source: String
    public init(start: Date, end: Date, devices: [Device], totalSent: UInt64? = nil, source: String) {
        self.start = start; self.end = end; self.devices = devices; self.totalSent = totalSent; self.source = source
    }
}

/// Cloud cameras can compete with calls and streams while recording or viewed live. With a router's per-device
/// counters Kilobat says what the cameras sent; without them it only says that cloud cameras can use a lot of upload,
/// with what their makers publish, and never puts a number on this home's.
public enum CameraUpload {
    /// One maker's published upload figure per camera, with where it says so.
    public struct Figure: Sendable, Equatable {
        public let maker: String
        /// "1 Mbps at 720p to 2 Mbps at 1080p, 10–15 Mbps for 2K and 4K"
        public let summary: String
        public let source: URL
    }
    /// Makers' own figures. Re-check before relying on a number.
    public static let figures: [Figure] = [
        Figure(maker: "Google Nest", summary: String(localized: "0.15–4 Mbps per camera, and up to 300–400 GB a month recording around the clock", comment: "Google's published upload figure for Nest cameras"),
               source: URL(string: "https://support.google.com/googlenest/answer/9245832")!),
        Figure(maker: "Ring", summary: String(localized: "1 Mbps at 720p and 2 Mbps at 1080p per device, 10 Mbps for 2K and 15 Mbps for 4K", comment: "Ring's published upload figure per device"),
               source: URL(string: "https://ring.com/support/articles/92bd2/Understanding-wifi-recommendations-for-Ring-devices")!),
        Figure(maker: "Arlo", summary: String(localized: "1–3 Mbps per camera depending on model, 2 Mbps per doorbell", comment: "Arlo's published upload figure per camera"),
               source: URL(string: "https://www.arlo.com/en_gb/support/faq/setup-and-configuration/what-are-the-minimum-requirements-for-installing-and-using-my-arlo-system")!),
    ]

    /// The cameras and doorbells among `devices`, including ones Kilobat is only fairly sure of; a weak hint isn't enough.
    public static func cameras(_ devices: [KnownDevice], router: String? = nil) -> [KnownDevice] {
        devices.filter { device in
            guard device.verdict != .ignored, device.mac != router else { return false }
            let guess = device.guess()
            return guess.type.films && (guess.confidence ?? .low) >= .medium
        }
    }

    /// What the cameras sent over a window, against everything the home sent.
    public struct Measured: Sendable, Equatable {
        public let cameras: Int
        public let sent: UInt64
        /// The cameras' share of the home's upload, 0–1; nil without a total.
        public let share: Double?
        public let days: Double
        public let source: String
        /// The busiest camera and what it sent.
        public let top: (name: String, sent: UInt64)?
        public static func == (a: Measured, b: Measured) -> Bool {
            a.cameras == b.cameras && a.sent == b.sent && a.share == b.share && a.days == b.days && a.source == b.source && a.top?.name == b.top?.name && a.top?.sent == b.top?.sent
        }
    }

    /// Nil when there are no cameras, the window has none of them, or they sent nothing.
    public static func measured(cameras: [KnownDevice], usage: DeviceUsageWindow) -> Measured? {
        guard !cameras.isEmpty, usage.end > usage.start,
              Set(usage.devices.map(\.mac)).count == usage.devices.count else { return nil }
        var sent: UInt64 = 0, counted = 0, top: (name: String, sent: UInt64)?
        for camera in cameras {
            let records = usage.devices.filter { camera.macs.contains($0.mac) }
            guard !records.isEmpty else { continue }
            var bytes: UInt64 = 0
            for record in records {
                let addition = bytes.addingReportingOverflow(record.sent)
                guard !addition.overflow else { return nil }
                bytes = addition.partialValue
            }
            let addition = sent.addingReportingOverflow(bytes)
            guard !addition.overflow else { return nil }
            counted += 1; sent = addition.partialValue
            if bytes > (top?.sent ?? 0) { top = (camera.label, bytes) }
        }
        guard counted > 0, sent > 0 else { return nil }
        // Only a matching WAN total supports a share of the home's upload. Client counters may
        // omit devices or cover LAN traffic; an inconsistent total is not evidence of 100%.
        let share = usage.totalSent.flatMap { total -> Double? in
            guard total >= sent else { return nil }
            return Double(sent) / Double(total)
        }
        return Measured(cameras: counted, sent: sent, share: share, days: max(usage.end.timeIntervalSince(usage.start) / 86_400, 1.0 / 24), source: usage.source, top: top)
    }

    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .decimal) }
    static func period(_ days: Double) -> String {
        if days >= 6.5 && days <= 7.5 { return String(localized: "this week", comment: "Camera upload: the stretch the numbers cover") }
        if days < 1.5 { return String(localized: "today", comment: "Camera upload: the stretch the numbers cover") }
        return String(localized: "in the last \(Int(days.rounded())) days", comment: "Camera upload: the stretch the numbers cover; the argument is a number of days")
    }

    /// "Your 3 cameras sent 41 GB this week, 60% of your upload (OpenWrt nlbwmon’s counters)."
    public static func sentence(_ measured: Measured) -> String {
        let amount = bytes(measured.sent), when = period(measured.days)
        let lead: String = measured.cameras == 1
            ? String(localized: "Your camera sent \(amount) \(when)", comment: "Camera upload from the router's counters; the arguments are an amount such as 41 GB and a stretch such as “this week”")
            : String(localized: "Your \(measured.cameras) cameras sent \(amount) \(when)", comment: "Camera upload from the router's counters; the arguments are a count, an amount such as 41 GB and a stretch such as “this week”")
        let share = measured.share.map { String(localized: ", \(Int(($0 * 100).rounded()))% of your upload", comment: "Camera upload: the cameras' share of everything the home sent, such as “, 60% of your upload”") } ?? ""
        return lead + share + String(localized: " (\(measured.source)’s counters).", comment: "Camera upload: where the numbers came from; the argument is a router integration such as OpenWrt nlbwmon")
    }

    /// Without a router's per-device counters: that cloud cameras can upload a lot, with the makers' own figures for
    /// the brands found here (else all of them). Never a measurement.
    public static func estimateNote(cameras: [KnownDevice]) -> String {
        let brands = Set(cameras.compactMap { $0.guess().brand?.lowercased() })
        let mine = figures.filter { figure in brands.contains { figure.maker.lowercased().contains($0) || $0.contains(figure.maker.lowercased()) } }
        let shown = (mine.isEmpty ? figures : mine).map { "\($0.maker): \($0.summary)" }.joined(separator: "; ")
        let count: String = cameras.count == 1
            ? String(localized: "Kilobat sees a camera on this network.", comment: "Camera upload without a router connection")
            : String(localized: "Kilobat sees \(cameras.count) cameras on this network.", comment: "Camera upload without a router connection; the argument is a count")
        return count + " " + String(localized: "Cloud cameras can use a lot of upload. Their makers’ own figures: \(shown).", comment: "Camera upload without a router connection; the argument lists makers' published figures, such as “Ring: 1 Mbps at 720p…”")
            + " " + String(localized: "Kilobat can’t measure them without your router’s per-device counters.", comment: "Camera upload without a router connection")
    }

    /// What to say beside an upload problem: the measured line when the router counted the cameras, else the makers' figures.
    public static func note(cameras: [KnownDevice], usage: DeviceUsageWindow?) -> String? {
        guard !cameras.isEmpty else { return nil }
        if let usage, let measured = measured(cameras: cameras, usage: usage) { return sentence(measured) }
        return estimateNote(cameras: cameras)
    }
}

/// A call report's or Health's mention of the cameras, when upload was the problem.
public struct CameraUploadNote: Codable, Sendable, Equatable {
    /// How many cameras and doorbells Kilobat recognised on the network.
    public let cameras: Int
    /// Measured from a router's per-device counters, or only the makers' published figures.
    public let measured: Bool
    public let text: String
    public init(cameras: Int, measured: Bool, text: String) { self.cameras = cameras; self.measured = measured; self.text = text }
    public static func make(cameras: [KnownDevice], usage: DeviceUsageWindow?) -> CameraUploadNote? {
        guard let text = CameraUpload.note(cameras: cameras, usage: usage) else { return nil }
        let measured = usage.flatMap { CameraUpload.measured(cameras: cameras, usage: $0) } != nil
        return CameraUploadNote(cameras: cameras.count, measured: measured, text: (measured ? "" : String(localized: "Cameras may be part of it. ", comment: "Before the makers' upload figures, when upload was the problem")) + text)
    }
}

/// Extension point for internet-qualified per-device traffic. No current adapter fills it: UniFi/RouterOS client
/// counters can include LAN traffic; nlbwmon measures traffic crossing configured local subnets, not a verified WAN
/// interface; FRITZ!Box has no per-client counters. Keep the makers' guidance until a provider can establish the
/// actual interval and internet scope (plus a matching WAN total before showing a share).
@MainActor public enum DeviceUsage {
    /// Internet-qualified counters for this identified home network, or nil when the router can't say.
    public static var provider: ((_ network: String, _ start: Date, _ end: Date) -> DeviceUsageWindow?)? = nil
    public static func window(network: String, from start: Date, to end: Date) -> DeviceUsageWindow? {
        guard !network.isEmpty, network != "unknown", end > start,
              let usage = provider?(network, start, end), usage.end > usage.start,
              usage.start >= start, usage.end <= end else { return nil }
        return usage
    }
    /// The last seven days on the named network, as the Devices tab and Health show it.
    public static func week(network: String, now: Date = Date()) -> DeviceUsageWindow? {
        window(network: network, from: now.addingTimeInterval(-7 * 86_400), to: now)
    }
}

extension SpeedTestResult {
    /// How much the ping rose while the test uploaded, in milliseconds; nil when the test couldn't tell.
    public var uploadAddedLatency: Double? {
        guard uploadSeconds >= 2, let idle = baseline.average, idle.isFinite, baseline.samples.count >= 3, (baseline.lossPercent ?? 0) <= 10,
              let loaded = uploadLoaded.average else { return nil }
        return max(0, loaded - idle)
    }
    /// The upload direction backs up: the ping rose 60 ms or more while it uploaded, Kilobat's "High" bufferbloat.
    public var uploadCongested: Bool { (uploadAddedLatency ?? 0) >= 60 }
}

extension CameraUpload {
    /// Health's line when the latest speed test found the upload congested and cameras are on the network: what they
    /// sent with a router's counters, else how much makers say one can use. Nil otherwise.
    public static func healthNote(speed: SpeedTestResult?, cameras: [KnownDevice], usage: DeviceUsageWindow?, now: Date = Date()) -> String? {
        guard let speed, speed.uploadCongested, now.timeIntervalSince(speed.date) < 86_400, !cameras.isEmpty else { return nil }
        if let usage, let measured = measured(cameras: cameras, usage: usage) { return sentence(measured) }
        return cameras.count == 1
            ? String(localized: "A camera here may be part of it: makers publish about 1–4 Mbps of upload for one HD camera.", comment: "Health, when upload was congested and there's a camera; not measured")
            : String(localized: "\(cameras.count) cameras here may be part of it: makers publish about 1–4 Mbps of upload for each HD camera.", comment: "Health, when upload was congested and there are cameras; not measured; the argument is a count")
    }
}

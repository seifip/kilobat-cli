import Foundation

/// One iperf3 run between this Mac and a server the person names, read from `iperf3 -J`.
public struct LANTestResult: Codable, Sendable, Equatable {
    public let host: String
    /// upload: this Mac sends; download: the server sends (`--reverse`).
    public let direction: String
    public let streams: Int
    public let seconds: Double
    public let sentMbps: Double
    public let receivedMbps: Double
    public let bytes: Int
    /// TCP retransmissions on the sending side, when iperf3 reports them (only the sender knows).
    public let retransmits: Int?

    public var summary: String {
        let mbps = String(format: "%.0f", receivedMbps), time = String(format: "%.0f", seconds), moved = TrafficFormat.bytes(UInt64(max(0, bytes)))
        var text = direction == "upload" ? String(localized: "This Mac → \(host): \(mbps) Mbps received over \(time) s") : String(localized: "\(host) → this Mac: \(mbps) Mbps received over \(time) s")
        if streams > 1 { text += " " + String(localized: "on \(streams) streams") }
        if let retransmits { text += " · " + String(localized: "\(retransmits) retransmissions") }
        return text + " · " + String(localized: "\(moved) moved") + ". " + String(localized: "Measures the path between the two devices, not your internet connection.")
    }

    /// Reads iperf3's JSON. An `error` in it becomes the thrown message.
    public static func parse(_ data: Data, host: String, reverse: Bool) throws -> LANTestResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiagnosticError(String(localized: "iperf3 didn't return a result.")) }
        if let error = object["error"] as? String { throw DiagnosticError("iperf3: \(error)") }
        guard let end = object["end"] as? [String: Any], let sent = end["sum_sent"] as? [String: Any], let received = end["sum_received"] as? [String: Any] else {
            throw DiagnosticError(String(localized: "iperf3's result has no totals."))
        }
        func number(_ dictionary: [String: Any], _ key: String) -> Double { (dictionary[key] as? NSNumber)?.doubleValue ?? 0 }
        let start = object["start"] as? [String: Any], test = start?["test_start"] as? [String: Any]
        return LANTestResult(host: host, direction: reverse ? "download" : "upload", streams: (test?["num_streams"] as? NSNumber)?.intValue ?? 1,
                             seconds: number(received, "seconds"), sentMbps: number(sent, "bits_per_second") / 1_000_000,
                             receivedMbps: number(received, "bits_per_second") / 1_000_000, bytes: Int(number(received, "bytes")),
                             retransmits: (sent["retransmits"] as? NSNumber)?.intValue)
    }
}

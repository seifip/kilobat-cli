import Foundation

/// When a one-time hint may appear. Hints point at something useful at the moment it's useful, so they are rare on
/// purpose: one at a time, one a day, never in the first hour, each at most once ever.
public enum HintPolicy {
    public static let spacing: TimeInterval = 86_400
    public static let settle: TimeInterval = 3_600

    public static func canShow(id: String, seen: Set<String>, showing: Bool, onboardingDone: Bool, firstSeen: Date, lastShown: Date?, now: Date = Date()) -> Bool {
        guard onboardingDone, !showing, !seen.contains(id), now.timeIntervalSince(firstSeen) >= settle else { return false }
        return lastShown.map { now.timeIntervalSince($0) >= spacing } ?? true
    }

    /// A Wi-Fi name that reads like a phone's hotspot. Only ever asked about, never assumed.
    public static func looksLikePhoneHotspot(_ ssid: String?) -> Bool {
        guard let name = ssid?.lowercased(), !name.isEmpty else { return false }
        if ["iphone", "ipad", "android", "hotspot", "redmi", "xiaomi", "oneplus", "huawei"].contains(where: name.contains) { return true }
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { ["galaxy", "pixel", "oppo", "poco", "realme"].contains($0) }
    }

    /// Wi-Fi at −75 dBm or worse across at least three checks spanning three minutes or more, in the last six.
    public static func weakSignalLasted(_ readings: [(date: Date, rssi: Int?)], now: Date = Date()) -> Bool {
        let recent = readings.filter { now.timeIntervalSince($0.date) <= 360 }.sorted { $0.date < $1.date }
        guard recent.count >= 3, let first = recent.first, let last = recent.last, last.date.timeIntervalSince(first.date) >= 180 else { return false }
        return recent.allSatisfy { ($0.rssi ?? 0) <= -75 && $0.rssi != nil }
    }

    /// A finished outage of two minutes or more in the last day: long enough to be worth reporting.
    public static func reportableOutage(_ events: [NetworkEvent], now: Date = Date()) -> Bool {
        events.contains { event in
            guard event.kind == "Unreachable", let end = event.end else { return false }
            return now.timeIntervalSince(end) <= 86_400 && end.timeIntervalSince(event.start) >= 120
        }
    }
}

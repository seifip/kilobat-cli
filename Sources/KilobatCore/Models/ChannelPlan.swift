import Foundation

/// Where Wi-Fi channels sit in each band, how wide networks overlap, and which channel a router could move to.
/// An estimate from the networks this Mac hears: it can't see non-Wi-Fi interference, how busy each network is, or
/// radar on DFS channels, so the advice names what it's based on.
public enum ChannelPlan {
    public static let bands = ["2.4 GHz", "5 GHz", "6 GHz"]

    /// A channel's occupied frequencies, in MHz.
    public struct Span: Sendable, Equatable {
        public let low: Double
        public let high: Double
        public var center: Double { (low + high) / 2 }
        public var width: Double { high - low }
        public init(low: Double, high: Double) { self.low = low; self.high = high }
        public init(center: Double, width: Double) { low = center - width / 2; high = center + width / 2 }
        public func overlap(_ other: Span) -> Double { max(0, min(high, other.high) - max(low, other.low)) }
    }

    /// A 20 MHz channel's centre frequency.
    public static func frequency(channel: Int, band: String) -> Double? {
        switch band {
        case "2.4 GHz": channel == 14 ? 2484 : (1...13).contains(channel) ? Double(2407 + 5 * channel) : nil
        case "5 GHz": (32...177).contains(channel) ? Double(5000 + 5 * channel) : nil
        case "6 GHz": (1...233).contains(channel) ? Double(5950 + 5 * channel) : nil
        default: nil
        }
    }

    /// The centre channel of a bonded channel in the standard plan, for when the beacon didn't say.
    public static func blockCenter(channel: Int, band: String, width: Int) -> Int {
        let n = max(1, width / 20)
        guard n > 1 else { return channel }
        switch band {
        case "2.4 GHz": return channel <= 7 ? channel + 2 : channel - 2
        case "5 GHz":
            let base = channel >= 149 ? 149 : 36, step = 4 * n
            return (channel - base) / step * step + base + 2 * (n - 1)
        case "6 GHz":
            let step = 4 * n
            return (channel - 1) / step * step + 1 + 2 * (n - 1)
        default: return channel
        }
    }

    /// The frequencies a network occupies: its width around the centre the beacon names, or the standard plan's.
    public static func span(channel: Int, band: String, widthMHz: Int, center: Int? = nil) -> Span {
        let width = max(20, widthMHz)
        let middle = width > 20 ? (center ?? blockCenter(channel: channel, band: band, width: width)) : channel
        let frequency = Self.frequency(channel: middle, band: band) ?? Self.frequency(channel: channel, band: band) ?? 0
        return Span(center: frequency, width: Double(width))
    }

    /// 5 GHz channels 52–144 share the band with weather and military radar: a router must listen first and leave when
    /// it hears radar (Dynamic Frequency Selection).
    public static func isDFS(channel: Int, band: String) -> Bool { band == "5 GHz" && (52...144).contains(channel) }
    public static let dfsRange = Span(low: 5250, high: 5730)
    public static func touchesDFS(_ span: Span, band: String) -> Bool { band == "5 GHz" && span.overlap(dfsRange) > 0 }

    /// The 20 MHz channels a band's axis is drawn over. 5 GHz skips 68–96, which Wi-Fi doesn't use.
    public static func channels(band: String) -> [Int] {
        switch band {
        case "2.4 GHz": Array(1...13)
        case "5 GHz": Array(stride(from: 36, through: 64, by: 4)) + Array(stride(from: 100, through: 144, by: 4)) + Array(stride(from: 149, through: 177, by: 4))
        case "6 GHz": Array(stride(from: 1, through: 233, by: 4))
        default: []
        }
    }

    /// The stretches of spectrum a band's graph spans: 5 GHz in two pieces around 5350–5470 MHz, which Wi-Fi doesn't use.
    /// Widened to fit any network that reaches past the usual edges (channel 14, UNII-4).
    public static func axis(band: String, networks: [NearbyNetwork] = []) -> [Span] {
        let spans = networks.filter { $0.band == band && $0.channel > 0 }.map(\.span)
        let low = spans.map(\.low).min() ?? .infinity, high = spans.map(\.high).max() ?? -.infinity
        switch band {
        case "2.4 GHz": return [Span(low: min(2401, low), high: max(2483, high))]
        case "5 GHz": return [Span(low: min(5170, low), high: 5350), Span(low: 5470, high: max(5850, high))]
        case "6 GHz": return [Span(low: 5945, high: max(7125, high))]
        default: return []
        }
    }

    /// Where a router could put a network of this width: each block's first channel.
    public static func candidates(band: String, width: Int) -> [Int] {
        switch band {
        case "2.4 GHz": return [1, 6, 11]
        case "5 GHz":
            switch width {
            case 160...: return [36, 100]
            case 80: return [36, 52, 100, 116, 132, 149]
            case 40: return [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157]
            default: return channels(band: band).filter { $0 <= 165 }
            }
        case "6 GHz":
            let step = 4 * max(1, min(width, 320) / 20)
            return Array(stride(from: 1, through: 233, by: step)).filter { $0 + step - 4 <= 233 }
        default: return []
        }
    }

    // MARK: Advice

    public struct Advice: Sendable, Equatable {
        public struct Row: Sendable, Equatable, Identifiable {
            public let channel: Int
            /// Overlap with other networks, weighted by how strong each is: about 1 per dB above −100 dBm for a network
            /// covering the whole channel.
            public let cost: Double
            public let dfs: Bool
            public var id: Int { channel }
        }
        public let band: String
        /// The width the advice is for: the Mac's own on this band, or a common one.
        public let widthMHz: Int
        /// The channel this Mac is on, when it's on this band.
        public let current: Int?
        public let recommended: Int?
        public let rows: [Row]
        /// Other networks overlapping the current channel (the Mac's own network's radios left out).
        public let overlappingCurrent: Int
        /// Other networks heard on this band.
        public let networksSeen: Int
        /// The advice in plain words.
        public let sentence: String
        /// A few rows for a compact summary: the current channel, the recommendation and the quietest others, in channel order.
        public var summary: [Row] {
            guard rows.count > 6 else { return rows }
            let keep = Set([current, recommended].compactMap { $0 } + rows.sorted { $0.cost < $1.cost }.prefix(4).map(\.channel))
            return rows.filter { keep.contains($0.channel) }.prefix(6).map { $0 }
        }
    }

    /// Weighted overlap of `span` with `networks`.
    public static func cost(_ span: Span, networks: [NearbyNetwork]) -> Double {
        networks.reduce(0) { total, network in
            let overlap = network.span.overlap(span)
            guard overlap > 0 else { return total }
            return total + Double(max(1, network.rssi + 100)) * overlap / span.width
        }
    }

    /// Which channel on `band` overlaps the fewest strong networks. `ssid` is the Mac's own network, whose radios are left
    /// out (a mesh shares its channel on purpose); `channel` and `width` are the Mac's own on this band, when it's on it.
    /// A DFS channel is suggested only when it is clearly quieter than every other.
    public static func advice(band: String, networks: [NearbyNetwork], ssid: String?, channel: Int?, width: Int?) -> Advice {
        let others = networks.filter { $0.band == band && $0.channel > 0 && (ssid == nil || $0.ssid != ssid) }
        let ownWidth = width
        let width = band == "2.4 GHz" ? 20 : width ?? (band == "6 GHz" ? 160 : 80)
        var choices = candidates(band: band, width: width)
        // The Mac's own channel is always a row, even off the standard plan.
        let currentStart = channel.map { current in
            band == "2.4 GHz" ? current : blockCenter(channel: current, band: band, width: width) - 2 * (max(1, width / 20) - 1)
        }
        if let currentStart, !choices.contains(currentStart) { choices = (choices + [currentStart]).sorted() }
        let rows = choices.map { start in
            let span = span(channel: start, band: band, widthMHz: width)
            return Advice.Row(channel: start, cost: (cost(span, networks: others) * 10).rounded() / 10, dfs: touchesDFS(span, band: band))
        }
        let safe = rows.filter { !$0.dfs }, quiet = { (list: [Advice.Row]) in list.min { $0.cost != $1.cost ? $0.cost < $1.cost : $0.channel < $1.channel } }
        var best = quiet(safe) ?? quiet(rows)
        if let dfs = quiet(rows.filter(\.dfs)), let plain = best, !plain.dfs, plain.cost - dfs.cost >= 20, dfs.cost * 1.5 <= plain.cost { best = dfs }
        // Staying put wins a near tie: changing channel costs a reconnect for every device.
        if let currentStart, let here = rows.first(where: { $0.channel == currentStart }), let pick = best, here.cost - pick.cost < 10 { best = here }
        let currentSpan = channel.map { span(channel: $0, band: band, widthMHz: width) }
        let overlapping = currentSpan.map { span in others.filter { $0.span.overlap(span) > 0 }.count } ?? 0
        return Advice(band: band, widthMHz: width, current: currentStart, recommended: others.isEmpty ? currentStart : best?.channel, rows: rows,
                      overlappingCurrent: overlapping, networksSeen: others.count,
                      sentence: sentence(band: band, width: width, current: currentStart, best: best, others: others.count, overlapping: overlapping, wide24: band == "2.4 GHz" && (ownWidth ?? 20) > 20))
    }

    static func sentence(band: String, width: Int, current: Int?, best: Advice.Row?, others: Int, overlapping: Int, wide24: Bool) -> String {
        guard others > 0 else {
            return current == nil ? String(localized: "No other networks heard on \(band).", comment: "Channel advice; the argument is a Wi-Fi band such as 5 GHz")
                                  : String(localized: "No other networks heard on \(band). Your channel is fine.", comment: "Channel advice; the argument is a Wi-Fi band")
        }
        guard let best else { return String(localized: "Not enough to suggest a channel.", comment: "Channel advice") }
        var text: String
        if let current, current == best.channel {
            text = String(localized: "Channel \(current) is already the least crowded choice here. Keep it.", comment: "Channel advice; the argument is a channel number")
        } else if let current {
            text = overlapping == 1
                ? String(localized: "Try channel \(best.channel) at \(width) MHz in your router’s settings. One other network overlaps channel \(current).", comment: "Channel advice; the arguments are a channel, a width and the current channel")
                : String(localized: "Try channel \(best.channel) at \(width) MHz in your router’s settings. \(overlapping) other networks overlap channel \(current).", comment: "Channel advice; the arguments are a channel, a width, a count and the current channel")
        } else {
            text = String(localized: "On \(band), channel \(best.channel) at \(width) MHz overlaps the fewest strong networks.", comment: "Channel advice when this Mac is on another band; band, channel, width")
        }
        if best.dfs && current != best.channel {
            text += " " + String(localized: "It’s a DFS channel: the router must leave it for a while if it hears radar, and some older devices can’t use it.", comment: "Channel advice: a DFS channel caveat")
        }
        if wide24 {
            text += " " + String(localized: "Your network is 40 MHz wide on 2.4 GHz, which covers most of the band; 20 MHz leaves room for neighbours and is often steadier.", comment: "Channel advice on 2.4 GHz")
        }
        return text
    }
}

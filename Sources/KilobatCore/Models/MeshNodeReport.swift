import Foundation

/// The joined network's nodes as Kilobat sees them now, and whether the Mac clings to a far one. The app shows it,
/// and the CLI and MCP read it from the app, which has the Location permission BSSIDs need.
public struct NodeReport: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Not on Wi-Fi, or on Wi-Fi with traffic leaving through a cable.
        case notWiFi
        /// macOS hides BSSIDs from apps without Location permission.
        case noLocation
        case notJoined
        /// One node (or one access point) heard: nothing to compare.
        case singleNode
        /// The Mac roamed less than a minute ago.
        case settling
        case fine
        /// A better node is in range; Kilobat waits two minutes before saying so.
        case watching
        case stuck
    }
    public let date: Date
    public let ssid: String?
    /// The network's `networkKey`.
    public let network: String?
    public let state: State
    public let nodes: [MeshNode]
    public let stuck: StuckNode?
    /// Times the Mac stayed on a far node on this network in the last 14 days, this one included.
    public let repeats: Int
    public init(date: Date, ssid: String?, network: String?, state: State, nodes: [MeshNode] = [], stuck: StuckNode? = nil, repeats: Int = 0) {
        self.date = date; self.ssid = ssid; self.network = network; self.state = state; self.nodes = nodes; self.stuck = stuck; self.repeats = repeats
    }
    public var current: MeshNode? { nodes.first(where: \.current) }
    /// Three or more in two weeks: worth a look at the mesh's own settings.
    public var keepsHappening: Bool { repeats >= 3 }

    /// "the Office node", or nil when it has no name yet.
    static func called(_ node: MeshNode) -> String? {
        node.name.map { String(localized: "the \($0) node", comment: "A Wi-Fi mesh node the user named, such as “the Office node”") }
    }

    public var headline: String? {
        stuck == nil ? nil : String(localized: "You’re on the far Wi-Fi node", comment: "Finding: the Mac stays on a distant mesh node while a closer one is in range")
    }
    /// "You’re on the Living room node at -78 dBm; the Office node is at -52 dBm."
    public var detail: String? { stuck.map(Self.detail) }
    static func detail(_ stuck: StuckNode) -> String {
        switch (called(stuck.node), called(stuck.better)) {
        case let (mine?, better?):
            String(localized: "You’re on \(mine) at \(stuck.rssi) dBm; \(better) is at \(stuck.betterRSSI) dBm.", comment: "Far mesh node; the arguments are two named nodes and their signals, such as “the Living room node”, -78, “the Office node”, -52")
        case let (nil, better?):
            String(localized: "You’re on a node at \(stuck.rssi) dBm; \(better) is at \(stuck.betterRSSI) dBm.", comment: "Far mesh node; the current node has no name. The arguments are its signal, a named node such as “the Office node”, and its signal")
        case let (mine?, nil):
            String(localized: "You’re on \(mine) at \(stuck.rssi) dBm; a node about \(stuck.difference) dB stronger is in range.", comment: "Far mesh node; the better node has no name. The arguments are a named node such as “the Living room node”, its signal and the difference in dB")
        case (nil, nil):
            String(localized: "You’re on a node at \(stuck.rssi) dBm; a node about \(stuck.difference) dB stronger is in range.", comment: "Far mesh node; neither node has a name. The arguments are the signal and the difference in dB")
        }
    }
    /// Why macOS stays, what to do, and when it keeps happening, what to change in the mesh.
    public var advice: String? {
        guard stuck != nil else { return nil }
        let first = String(localized: "macOS only moves once the signal drops to about -75 dBm. Reconnect, or turn Wi-Fi off and on, to switch.", comment: "Far mesh node advice")
        guard keepsHappening else { return first }
        return first + " " + String(localized: "This keeps happening here: check your mesh system’s steering or roaming settings, or move the nodes so they overlap less.", comment: "Far mesh node advice when it happened three or more times in two weeks")
    }
    /// The menu's line: "Office is 26 dB stronger" or "A node 26 dB stronger is in range".
    public var short: String? {
        guard let stuck else { return nil }
        if let name = stuck.better.name { return String(localized: "On the far node · \(name) is \(stuck.difference) dB stronger", comment: "Wi-Fi menu: the argument is a named mesh node such as Office, then the difference in dB") }
        return String(localized: "On the far node · one \(stuck.difference) dB stronger is in range", comment: "Wi-Fi menu: the argument is a difference in dB")
    }
}

/// A reconnect Kilobat made, and where the Mac ended up.
public struct NodeReconnect: Codable, Sendable, Equatable {
    public let method: NodeMove.Method
    /// The node the Mac is on now; nil when it didn't come back to the network in time.
    public let node: MeshNode?
    public let rssi: Int?
    /// Now on the node Kilobat was aiming for.
    public let better: Bool
    public let date: Date
    public init(method: NodeMove.Method, node: MeshNode?, rssi: Int?, better: Bool, date: Date = Date()) {
        self.method = method; self.node = node; self.rssi = rssi; self.better = better; self.date = date
    }
    /// "Now on the Office node at -52 dBm."
    public var sentence: String {
        guard let node, let rssi else { return String(localized: "Wi-Fi hasn’t rejoined yet. macOS joins a saved network on its own; check the Wi-Fi menu if it doesn’t.", comment: "After reconnecting to a closer mesh node") }
        if better {
            return NodeReport.called(node).map { String(localized: "Now on \($0) at \(rssi) dBm.", comment: "After reconnecting; the argument is a named node such as “the Office node”") }
                ?? String(localized: "Now on the stronger node at \(rssi) dBm.", comment: "After reconnecting to a closer mesh node")
        }
        return NodeReport.called(node).map { String(localized: "Still on \($0), at \(rssi) dBm: macOS chose it again. Try again from where the other node is closer.", comment: "After reconnecting; the argument is a named node such as “the Living room node”") }
            ?? String(localized: "Still on the same node, at \(rssi) dBm: macOS chose it again. Try again from where the other node is closer.", comment: "After reconnecting to a closer mesh node")
    }
}

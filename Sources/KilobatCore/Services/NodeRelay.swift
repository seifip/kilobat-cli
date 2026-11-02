import Foundation

/// `kilobat wifi nodes` and `wifi reconnect`, parsed. Arguments come after `wifi`, without `--json`.
public enum WiFiNodesCommand: Equatable, Sendable {
    case list
    /// Names a node by its id, a BSSID, its name or `current`; an empty name clears it.
    case name(node: String, name: String)
    case reconnect

    public static let usage = "Use wifi nodes [--json], wifi nodes name <node> <name> or wifi reconnect [--json]."
    public static func parse(_ args: [String]) throws -> WiFiNodesCommand {
        switch args.first {
        case "nodes" where args.count == 1: return .list
        case "nodes" where args.count >= 4 && ["name", "rename"].contains(args[1]):
            return .name(node: args[2], name: args.dropFirst(3).joined(separator: " "))
        case "reconnect" where args.count == 1: return .reconnect
        default: throw DiagnosticError(usage)
        }
    }
}

/// The JSON the CLI and MCP print for nodes and reconnects, built from what the app knows.
public enum NodeJSON {
    public static func radio(_ radio: NodeRadio) -> [String: Any] {
        ["bssid": radio.bssid, "rssi": radio.rssi, "channel": radio.channel, "band": radio.band, "widthMHz": radio.widthMHz,
         "estimatedMbps": (radio.estimatedMbps * 10).rounded() / 10]
    }
    public static func node(_ node: MeshNode) -> [String: Any] {
        ["id": node.id, "name": node.name ?? NSNull(), "current": node.current, "rssi": node.strongest.rssi, "bands": node.bands, "radios": node.radios.map(radio)]
    }
    public static func report(_ report: NodeReport?, locationAllowed: Bool) -> [String: Any] {
        guard let report else {
            return ["state": locationAllowed ? "checking" : "noLocation", "nodes": [Any](), "stuck": NSNull(), "repeats": 0,
                    "headline": NSNull(), "detail": NSNull(), "advice": NSNull()]
        }
        let stuck: Any = report.stuck.map { stuck -> [String: Any] in
            ["since": ISO8601DateFormatter().string(from: stuck.since), "minutes": Int(report.date.timeIntervalSince(stuck.since) / 60),
             "node": stuck.node.id, "nodeName": stuck.node.name ?? NSNull(), "rssi": stuck.rssi,
             "betterNode": stuck.better.id, "betterName": stuck.better.name ?? NSNull(), "betterRSSI": stuck.betterRSSI, "betterBand": stuck.betterBand,
             "differenceDB": stuck.difference, "currentEstimatedMbps": stuck.currentMbps.rounded(), "betterEstimatedMbps": stuck.betterMbps.rounded()]
        } ?? NSNull()
        return ["state": report.state.rawValue, "date": ISO8601DateFormatter().string(from: report.date), "ssid": report.ssid ?? NSNull(),
                "current": report.current?.id ?? NSNull(), "nodes": report.nodes.map(node), "stuck": stuck, "repeats": report.repeats,
                "headline": report.headline ?? NSNull(), "detail": report.detail ?? NSNull(), "advice": report.advice ?? NSNull()]
    }
    public static func reconnect(_ result: Result<NodeReconnect, DiagnosticError>) -> [String: Any] {
        switch result {
        case .success(let done):
            return ["reconnected": true, "method": done.method.rawValue, "better": done.better, "node": done.node.map(node) ?? NSNull(),
                    "rssi": done.rssi ?? NSNull(), "sentence": done.sentence]
        case .failure(let error): return ["reconnected": false, "error": error.message]
        }
    }
}

/// The app's side of the CLI's `nodes` relay: `nodes`, `nodes|reconnect` and `nodes|name|<node>|<name>`.
@MainActor public enum NodeRelay {
    public static func answer(_ action: String, watch: NodeWatch, locationAllowed: Bool) async -> Data? {
        let parts = action.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let value: [String: Any]
        switch parts.count > 1 ? parts[1] : "" {
        case "":
            value = NodeJSON.report(watch.report, locationAllowed: locationAllowed)
        case "reconnect":
            guard locationAllowed else { value = NodeJSON.reconnect(.failure(DiagnosticError(noLocation))); break }
            value = NodeJSON.reconnect(await watch.reconnect())
        case "name" where parts.count == 4:
            guard locationAllowed else { value = ["named": false, "error": noLocation]; break }
            if let node = watch.name(parts[2], as: parts[3]) { value = ["named": true, "node": NodeJSON.node(node)] }
            else { value = ["named": false, "error": "No such node in the latest reading. Run kilobat wifi nodes for their ids."] }
        default: return nil
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static let noLocation = "Kilobat needs Location access to see Wi-Fi nodes: allow it in System Settings › Privacy & Security › Location Services."
}

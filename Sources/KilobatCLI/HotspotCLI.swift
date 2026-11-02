import Foundation
import KilobatCore

/// `kilobat hotspot`: on a phone hotspot, whether the carrier caps it: the verdict, the measurements behind it and the
/// carrier's hotspot-rules page. Reads what the app kept (service speed's downloads, speed tests, Health's pings, video
/// sessions); `--detect` asks Cloudflare for the public address and RIPE NCC whose network it is, and saves nothing.
@MainActor enum HotspotCLI {
    struct Output: Encodable {
        /// The current network first (state notHotspot when it isn't one); with --all, every hotspot Kilobat has seen.
        let networks: [HotspotThrottleReport]
        /// From --detect: the public address's network and the carrier it matched.
        let lookup: Lookup?
    }
    struct Lookup: Encodable { let asn: Int?; let organization: String?; let country: String?; let carrier: String? }
    struct CarrierRow: Encodable { let id: String; let name: String; let country: String; let asns: [Int]; let page: String; let sharedWith: [String] }

    static func run(_ args: [String]) async throws {
        let options: HotspotThrottleReport.Options
        do { options = try HotspotThrottleReport.Options.parse(args) } catch { throw CLIError(HotspotThrottleReport.Options.usage) }
        if options.carriers {
            let rows = HotspotCarriers.all.map { CarrierRow(id: $0.id, name: $0.name, country: $0.country, asns: $0.asns, page: $0.page.absoluteString, sharedWith: $0.sharedWith) }
            if options.json { print(String(decoding: try DiagnosticsCLI.encode(["carriers": rows]), as: UTF8.self)); return }
            for row in rows { print("\(KilobatCLI.pad(row.id, 14))\(KilobatCLI.pad(row.name, 18))\(row.country)  \(row.page)") }
            print("Every carrier: \(HotspotCarriers.hub.absoluteString)")
            return
        }
        var pick: HotspotCarrier?
        if let name = options.carrier {
            guard let found = HotspotCarriers.find(name) else {
                throw CLIError("No page for “\(name)”. Pick one of: \(HotspotCarriers.all.map(\.id).joined(separator: ", ")), or see \(HotspotCarriers.hub.absoluteString).")
            }
            pick = found
        }
        var lookup: Lookup?
        if options.detect {
            do {
                let found = try await ProviderLookup.lookup(address: try await ExitPath.publicAddress().address)
                let carrier = HotspotCarriers.match(asn: found.asn, organization: found.organization, country: found.country)
                lookup = Lookup(asn: found.asn, organization: found.organization, country: found.country, carrier: carrier?.id)
                pick = carrier
            } catch { throw CLIError("Couldn’t look up the public address’s network: \(error.localizedDescription)") }
        }
        let output = await reports(all: options.all, carrier: pick.map { .init($0, source: options.detect ? "lookup" : "you") }, lookup: lookup)
        if options.json { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
        if let lookup {
            print("Public address’s network: \(lookup.organization ?? "unknown") (AS\(lookup.asn.map(String.init) ?? "?"))" + (lookup.carrier == nil ? ", no carrier page for it." : "."))
        }
        print(output.networks.map(\.text).joined(separator: "\n\n"))
    }

    /// `carrier` overrides the saved one for the current network, for this answer only.
    static func reports(all: Bool, carrier: HotspotThrottleReport.Carrier? = nil, lookup: Lookup? = nil, now: Date = Date()) async -> Output {
        let app = await WiFiCLI.connection()
        let store = TrafficStore(startMonitoring: false)
        let journal = NetworkJournal(), services = ServiceSpeedWatch.load(), log = HotspotWatch.load()
        let current = QuotaCLI.currentNetwork(store, app: app)
        let metered = WiFiCLI.currentCost(store, app: app).metered(os: await AwakeCLI.currentPath().expensive)
        let sample = journal.samples.last { $0.networkKey == current }
        func report(_ key: String, kind: HotspotKind?, carrier override: HotspotThrottleReport.Carrier?) -> HotspotThrottleReport {
            HotspotThrottleReport(network: key, networkName: log.networks[key]?.name ?? services.networks[key]?.name ?? sample?.networkName ?? key, kind: kind,
                                  transfers: services.networks[key]?.services ?? [:], speedTests: journal.speedTests,
                                  latency: journal.samples.filter { $0.networkKey == key }.compactMap(HotspotLatency.init),
                                  video: log.networks[key]?.video ?? [], carrier: override ?? log.carrier(for: key), now: now)
        }
        var networks: [HotspotThrottleReport] = []
        if let current {
            let kind = HotspotKind.classify(metered: metered, gateway: sample?.gateway, service: sample?.networkService)
            networks.append(report(current, kind: kind, carrier: carrier))
        }
        if all {
            let others = log.networks.filter { $0.key != current && $0.value.kind != nil }
                .sorted { ($0.value.lastSeen ?? .distantPast) > ($1.value.lastSeen ?? .distantPast) }
            networks += others.map { report($0.key, kind: $0.value.kind, carrier: nil) }
        }
        return Output(networks: networks, lookup: lookup)
    }
}

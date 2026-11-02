import Foundation
import KilobatCore

/// `kilobat service-speed`: how fast this Mac's own big downloads from GitHub, iCloud, Steam, npm and the rest ran on each
/// network, against the line, and the finding when one is slow while the rest is fast. Reads what the app kept; `--test`
/// downloads up to 25 MB from one service's public file now, never on a metered network, and saves nothing.
@MainActor enum ServiceSpeedCLI {
    struct Output: Encodable {
        /// The network the Mac was on last, first; with --all, every network with downloads in the last 30 days.
        let networks: [ServiceSpeedReport]
    }
    struct TestOutput: Encodable {
        let service: String
        let target: String
        let downloadedBytes: UInt64
        let seconds: Double
        let mbps: Double
        let lineMbps: Double?
        let percentOfLine: Double?
        let typicalHereMbps: Double?
    }
    struct Target: Encodable { let id: String; let name: String; let url: String; let file: String }

    static func run(_ args: [String]) async throws {
        let options: ServiceSpeedReport.Options
        do { options = try ServiceSpeedReport.Options.parse(args) } catch { throw CLIError(ServiceSpeedReport.Options.usage) }
        if options.list {
            let targets = ServiceSpeedTarget.all.map { Target(id: $0.id, name: $0.name, url: $0.url.absoluteString, file: $0.file) }
            if options.json { print(String(decoding: try DiagnosticsCLI.encode(["targets": targets]), as: UTF8.self)); return }
            for target in targets { print("\(target.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(target.name): \(target.file)") }
            print("Checked \(ServiceSpeedTarget.checked). A test downloads at most 25 MB.")
            return
        }
        if let name = options.test {
            guard let target = ServiceSpeedTarget.find(name) else {
                throw CLIError("No test for “\(name)”. Pick one of: \(ServiceSpeedTarget.all.map(\.id).joined(separator: ", ")).")
            }
            let output = try await test(target, megabytes: options.budgetMB)
            if options.json { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
            var line = "\(output.service): \(ServiceSpeedReport.mbps(output.mbps)) over \(TrafficFormat.bytes(output.downloadedBytes)) in \(String(format: "%.1f", output.seconds)) s"
            if let lineMbps = output.lineMbps, let percent = output.percentOfLine { line += String(format: ", %.0f%% of the line (%@)", percent, ServiceSpeedReport.mbps(lineMbps)) }
            print(line)
            if let typical = output.typicalHereMbps { print("Your own downloads from it on this network: typically \(ServiceSpeedReport.mbps(typical)).") }
            return
        }
        let output = reports(all: options.all)
        if options.json { print(String(decoding: try DiagnosticsCLI.encode(output), as: UTF8.self)); return }
        guard !output.networks.isEmpty else {
            print("No downloads measured yet. With the Kilobat app running, every download of 5 MB or more from GitHub, iCloud, Steam, npm and the rest adds to it. `kilobat service-speed --test github` measures one now.")
            return
        }
        print(output.networks.map(\.text).joined(separator: "\n\n"))
    }

    static func reports(all: Bool, now: Date = Date()) -> Output {
        let log = ServiceSpeedWatch.load(), tests = NetworkJournal().speedTests
        let ordered = log.networks.keys.sorted { a, b in
            (a == log.current ? 1 : 0, log.networks[a]?.services.values.joined().map(\.date).max() ?? .distantPast)
                > (b == log.current ? 1 : 0, log.networks[b]?.services.values.joined().map(\.date).max() ?? .distantPast)
        }
        return Output(networks: (all ? ordered : Array(ordered.prefix(1))).map { ServiceSpeedReport(log: log, network: $0, speedTests: tests, now: now) })
    }

    /// One test now. Refused on a metered network, as the app does.
    static func test(_ target: ServiceSpeedTarget, megabytes: Int) async throws -> TestOutput {
        let app = await WiFiCLI.connection()
        let store = TrafficStore(startMonitoring: false)
        let metered = WiFiCLI.currentCost(store, app: app).metered(os: await AwakeCLI.currentPath().expensive)
        let transfer: ServiceTransfer
        do { transfer = try await ServiceSpeedTest.run(target, metered: metered, bytes: megabytes * 1_000_000) }
        catch let refusal as ServiceSpeedTest.Refusal { throw CLIError(refusal.localizedDescription) }
        let report = reports(all: false).networks.first
        let line = report?.capacity?.mbps
        return TestOutput(service: target.name, target: target.url.absoluteString, downloadedBytes: transfer.bytes, seconds: transfer.seconds, mbps: transfer.mbps,
                          lineMbps: line, percentOfLine: line.map { transfer.mbps / $0 * 100 },
                          typicalHereMbps: report?.rows.first { $0.key == target.key }?.typicalMbps)
    }
}

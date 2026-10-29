import Foundation
import CoreWLAN

public struct CommandResult: Sendable {
    public let output: String
    public let status: Int32
}
public enum CommandRunner {
    public static func run(_ path: String, _ arguments: [String], timeout: Double = 8) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                defer { deadline.cancel() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
            } catch { return CommandResult(output: error.localizedDescription, status: -1) }
        }.value
    }
}

public actor DiagnosticProbe {
    public init() {}
    public func radio() -> RadioSample {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn(), wifi.wlanChannel() != nil else {
            return RadioSample(ssid: nil, interface: nil, rssi: nil, noise: nil, transmitMbps: nil, channel: nil, band: nil)
        }
        let channel = wifi.wlanChannel()
        let noise = wifi.noiseMeasurement()
        return RadioSample(bssid: wifi.bssid(), ssid: wifi.ssid(), interface: wifi.interfaceName,
                           rssi: wifi.rssiValue() == 0 ? nil : wifi.rssiValue(), noise: noise == 0 ? nil : noise,
                           transmitMbps: wifi.transmitRate() > 0 ? wifi.transmitRate() : nil,
                           channel: channel?.channelNumber, band: Self.band(channel?.channelBand))
    }
    public func scan() throws -> [NearbyNetwork] {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else { throw DiagnosticError("Wi-Fi is unavailable or switched off.") }
        return try wifi.scanForNetworks(withSSID: nil).enumerated().map { index, network in
            NearbyNetwork(id: network.bssid ?? "hidden-\(index)", ssid: network.ssid ?? "Hidden network",
                          rssi: network.rssiValue, noise: network.noiseMeasurement,
                          channel: network.wlanChannel?.channelNumber ?? 0, band: Self.band(network.wlanChannel?.channelBand) ?? "Unknown",
                          widthMHz: Self.width(network.wlanChannel?.channelWidth ?? .width20MHz))
        }.sorted { $0.rssi > $1.rssi }
    }
    private static func band(_ band: CWChannelBand?) -> String? {
        switch band { case .band2GHz: "2.4 GHz"; case .band5GHz: "5 GHz"; case .band6GHz: "6 GHz"; default: nil }
    }
    private static func width(_ width: CWChannelWidth) -> Int {
        switch width { case .width40MHz: 40; case .width80MHz: 80; case .width160MHz: 160; default: 20 }
    }
    public static func matches(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }
    public static func parsePing(_ output: String, host: String, interval: Double = 0.25) -> PingResult {
        var result = PingResult(host: host, samples: matches("time[=<]([0-9.]+)\\s*ms", in: output).compactMap(Double.init),
                   lossPercent: matches("([0-9.]+)% packet loss", in: output).first.flatMap(Double.init))
        let sequences = matches("icmp_seq=([0-9]+).*?time[=<]", in: output).compactMap(Double.init)
        if sequences.count == result.samples.count { result.sampleOffsets = sequences.map { $0 * interval } }
        return result
    }
    public static func ping(_ host: String, count: Int = 4, interval: Double = 0.25) async -> PingResult {
        let result = await CommandRunner.run("/sbin/ping", ["-n", "-c", String(count), "-i", String(interval), "-W", "1000", host], timeout: Double(count) + 3)
        return parsePing(result.output, host: host, interval: interval)
    }
    public static func serviceName(_ output: String, interface: String) -> String? {
        var service: String?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("("), let end = line.firstIndex(of: ")"), !line.contains("Hardware Port:") {
                service = String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            if line.contains("Device: \(interface))") { return service }
        }
        return nil
    }
    public func snapshot() async -> DiagnosticSnapshot {
        let radio = radio()
        async let route = CommandRunner.run("/sbin/route", ["-n", "get", "default"])
        async let services = CommandRunner.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        async let internet = Self.ping("1.1.1.1")
        async let dns = CommandRunner.run("/usr/bin/dig", ["+time=2", "+tries=1", "example.com"])
        async let portal = Self.portal()
        let routeOutput = await route.output
        let gateway = Self.matches("gateway:\\s+([^\\s]+)", in: routeOutput).first
        let router = if let gateway { await Self.ping(gateway) } else { nil as PingResult? }
        let routeInterface = Self.matches("interface:\\s+([^\\s]+)", in: routeOutput).first
        let wired = routeInterface.flatMap { $0 != radio.interface && $0.hasPrefix("en") ? $0 : nil }
        let service = Self.serviceName(await services.output, interface: wired ?? radio.interface ?? routeInterface ?? "en0")
        let dnsOutput = await dns.output
        let dnsTime = Self.matches("Query time: ([0-9.]+) msec", in: dnsOutput).first.flatMap(Double.init)
        let resolvers = await CommandRunner.run("/usr/sbin/scutil", ["--dns"])
        let servers = Array(Set(Self.matches("nameserver\\[[0-9]+\\] : ([^\\s]+)", in: resolvers.output))).sorted()
        return await DiagnosticSnapshot(date: Date(), radio: radio, gateway: gateway, router: router, internet: internet,
                                        dnsMilliseconds: dnsTime, dnsServers: servers, captivePortal: portal, networkService: service, wiredInterface: wired)
    }
    public static func portal() async -> Bool? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
            guard let http = response as? HTTPURLResponse else { return nil }
            return http.statusCode != 200 || !(String(decoding: data, as: UTF8.self).contains("<TITLE>Success</TITLE>")) || http.url?.host != "captive.apple.com"
        } catch { return nil }
    }
    /// Congestion estimate based on visible access points, not a spectrum measurement.
    public static func congestion(channel: Int, band: String, networks: [NearbyNetwork]) -> Double {
        networks.filter { $0.band == band }.reduce(0) { result, network in
            let distance = abs(network.channel - channel)
            let radius = band == "2.4 GHz" ? max(4, network.widthMHz / 5) : max(1, network.widthMHz / 5)
            guard distance < radius else { return result }
            return result + Double(max(1, network.rssi + 100)) * (1 - Double(distance) / Double(radius))
        }
    }
}
public struct DiagnosticError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

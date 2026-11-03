import Foundation
import Darwin
import CoreWLAN
import SystemConfiguration

public struct CommandResult: Sendable {
    public let output: String
    public let status: Int32
}
public enum CommandRunner {
    public static func run(_ path: String, _ arguments: [String], timeout: Double = 8) async -> CommandResult {
        guard !Task.isCancelled else { return CommandResult(output: "", status: -1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        defer { try? reader.close() }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { return CommandResult(output: "", status: -1) }
        do { try process.run() }
        catch { return CommandResult(output: error.localizedDescription, status: -1) }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(max(0, timeout))
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            // Bound each pass, including when a subprocess writes continuously.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                output.append(contentsOf: buffer.prefix(count))
            }
        }
        while process.isRunning && !Task.isCancelled && clock.now < deadline {
            drain()
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            process.terminate()
            let grace = clock.now + .milliseconds(100)
            while process.isRunning && clock.now < grace && !Task.isCancelled {
                drain()
                try? await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        drain()
        // A descendant may keep the pipe open. Never wait for EOF or for an uninterruptible process.
        return CommandResult(output: String(decoding: output, as: UTF8.self), status: process.isRunning ? -1 : process.terminationStatus)
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
        let standard = WiFiLink.standard(phyMode: wifi.activePHYMode().rawValue, band: Self.band(channel?.channelBand))
        return RadioSample(bssid: wifi.bssid(), ssid: wifi.ssid(), interface: wifi.interfaceName,
                           rssi: wifi.rssiValue() == 0 ? nil : wifi.rssiValue(), noise: noise == 0 ? nil : noise,
                           transmitMbps: wifi.transmitRate() > 0 ? wifi.transmitRate() : nil,
                           channel: channel?.channelNumber, band: Self.band(channel?.channelBand),
                           widthMHz: channel.flatMap { Self.knownWidth($0.channelWidth) }, standard: standard?.name, phyMode: standard?.phy,
                           security: WiFiLink.security(wifi.security().rawValue)?.name,
                           transmitPowerDBm: WiFiLink.dBm(milliwatts: wifi.transmitPower()), countryCode: wifi.countryCode())
    }
    public func scan() throws -> [NearbyNetwork] {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else { throw DiagnosticError(String(localized: "Wi-Fi is unavailable or switched off.")) }
        return try wifi.scanForNetworks(withSSID: nil).enumerated().map { index, network in
            NearbyNetwork(id: network.bssid ?? "hidden-\(index)", ssid: network.ssid ?? "Hidden network",
                          rssi: network.rssiValue, noise: network.noiseMeasurement,
                          channel: network.wlanChannel?.channelNumber ?? 0, band: Self.band(network.wlanChannel?.channelBand) ?? "Unknown",
                          widthMHz: Self.width(network.wlanChannel?.channelWidth ?? .width20MHz),
                          security: WiFiLink.strongest(supported: Set(WiFiLink.securityValues.filter { CWSecurity(rawValue: $0).map(network.supportsSecurity) ?? false }))
                            .flatMap { WiFiLink.security($0)?.name })
        }.sorted { $0.rssi > $1.rssi }
    }
    static func band(_ band: CWChannelBand?) -> String? {
        switch band { case .band2GHz: "2.4 GHz"; case .band5GHz: "5 GHz"; case .band6GHz: "6 GHz"; default: nil }
    }
    static func width(_ width: CWChannelWidth) -> Int {
        switch width { case .width40MHz: 40; case .width80MHz: 80; case .width160MHz: 160; default: 20 }
    }
    /// CoreWLAN has no 320 MHz case yet. Do not report an unknown negotiated width as 20 MHz.
    private static func knownWidth(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
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
    /// `checkPortal` false leaves `captivePortal` nil, for the app, which looks for a sign-in page on its own schedule.
    public func snapshot(checkPortal: Bool = true) async -> DiagnosticSnapshot {
        let radio = radio()
        async let route = CommandRunner.run("/sbin/route", ["-n", "get", "default"])
        async let services = CommandRunner.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        async let internet = Self.ping("1.1.1.1")
        async let dns = CommandRunner.run("/usr/bin/dig", ["+time=2", "+tries=1", "example.com"])
        async let portal = checkPortal ? Self.portal() : nil
        let routeOutput = await route.output
        let gateway = Self.matches("gateway:\\s+([^\\s]+)", in: routeOutput).first
        let routeInterface = Self.matches(#"interface:\s+(\S+)"#, in: routeOutput).first
        let tunneled = routeInterface.map { TrafficRoute.tunnelInterface(Substring($0)) } ?? false
        let primary = tunneled ? Self.physicalRoute() : (routeInterface, gateway)
        let physicalGateway = primary.1
        let wired = primary.0.flatMap { $0 != radio.interface && $0.hasPrefix("en") ? $0 : nil }
        let router = if let physicalGateway { await Self.ping(physicalGateway) } else { nil as PingResult? }
        let mac: String?
        if let wired, let physicalGateway {
            mac = await ExpertTools.devices().first { $0.interface == wired && $0.address == physicalGateway }?.mac
        } else { mac = nil }
        let service = Self.serviceName(await services.output, interface: wired ?? radio.interface ?? routeInterface ?? "en0")
        let dnsOutput = await dns.output
        let dnsTime = Self.matches("Query time: ([0-9.]+) msec", in: dnsOutput).first.flatMap(Double.init)
        let resolvers = await CommandRunner.run("/usr/sbin/scutil", ["--dns"])
        let servers = Array(Set(Self.matches("nameserver\\[[0-9]+\\] : ([^\\s]+)", in: resolvers.output))).sorted()
        return await DiagnosticSnapshot(date: Date(), radio: radio, gateway: physicalGateway, router: router, internet: internet,
                                        dnsMilliseconds: dnsTime, dnsServers: servers, captivePortal: portal, networkService: service, wiredInterface: wired, physicalGateway: physicalGateway, gatewayMAC: mac, tunneledRoute: tunneled)
    }
    /// Find the underlying service when the VPN owns the default route.
    private static func physicalRoute() -> (String?, String?) {
        func pair(_ state: [String: Any], interfaceKey: String) -> (String, String)? {
            guard let interface = state[interfaceKey] as? String, interface.hasPrefix("en"),
                  let router = state["Router"] as? String, AddressRange.parse(router) != nil else { return nil }
            return (interface, router)
        }
        if let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let primary = pair(global, interfaceKey: "PrimaryInterface") { return primary }
        let services = SCDynamicStoreCopyMultiple(nil, nil, [#"State:/Network/Service/[^/]+/IPv4"#] as CFArray) as? [String: [String: Any]] ?? [:]
        let candidates = Set(services.values.compactMap { pair($0, interfaceKey: "InterfaceName").map { $0.0 + "|" + $0.1 } })
        // With multiple possible physical routers, do not guess which network is home.
        guard candidates.count == 1, let candidate = candidates.first else { return (nil, nil) }
        let parts = candidate.components(separatedBy: "|")
        return (parts[0], parts[1])
    }

    /// True when a sign-in page is in the way, nil when neither check page answered.
    public static func portal() async -> Bool? {
        switch await CaptivePortal.check(timeout: 4).state {
        case .open: false
        case .portal: true
        case .offline: nil
        }
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

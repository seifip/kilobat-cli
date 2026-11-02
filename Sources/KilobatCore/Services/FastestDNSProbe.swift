import Foundation
import Network

/// Asks one resolver about one name, and times a TCP connection: what a quiet run is made of. Tests pass their own.
public protocol DNSProbing: Sendable {
    func lookup(_ name: String, server: String) async -> DNSLookup
    /// Milliseconds to open a TCP connection to `address` on port 443, nil when it didn't open within two seconds.
    func connect(_ address: String) async -> Double?
}

/// The Mac's own tools: dig straight at the resolver's address (so the Mac's cache and its current DNS setting stay
/// out of it) and Network.framework for connects. Plain DNS over UDP, as networksetup's servers are used.
public struct SystemDNSProbe: DNSProbing {
    public init() {}
    public func lookup(_ name: String, server: String) async -> DNSLookup {
        guard DNSAddress.valid(server), ExpertTools.validHost(name) else { return DNSLookup(ms: nil, status: nil) }
        let result = await CommandRunner.run("/usr/bin/dig", ["@" + server, "+tries=1", "+time=2", name, "A"], timeout: 3)
        return DNSLookup.parse(dig: result.output, exitStatus: result.status)
    }
    public func connect(_ address: String) async -> Double? {
        guard DNSAddress.valid(address) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 443, using: .tcp)
        let start = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(Date().timeIntervalSince(start) * 1000); connection.cancel()
                case .failed, .waiting: once.finish(nil); connection.cancel()
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.finish(nil); connection.cancel() }
        }
    }
    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<Double?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<Double?, Never>) { self.continuation = continuation }
        func finish(_ value: Double?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// One quiet run: each candidate on its own, side by side.
public enum FastestDNSMeter {
    /// About two dozen small UDP queries per resolver and a few TCP handshakes (no data) to CDN addresses: a few kilobytes.
    public static func run(candidates: [DNSResolverChoice], networkServers: [String], probe: DNSProbing, date: Date = Date(),
                           missingName: String = FastestDNS.missingName(), pause: Duration = .milliseconds(40)) async -> DNSRun {
        struct Partial: Sendable { var run: DNSResolverRun; var cdn: [String: String] }
        let partials = await withTaskGroup(of: Partial?.self) { group in
            for candidate in candidates {
                guard let server = candidate.isNetwork ? networkServers.first : candidate.servers.first else { continue }
                group.addTask {
                    var first: [Double] = [], again: [Double] = [], queries = 0, failures = 0
                    for name in FastestDNS.domains {
                        guard !Task.isCancelled else { return nil }
                        for repeated in [false, true] {
                            let answer = await probe.lookup(name, server: server)
                            queries += 1
                            if answer.answered, let ms = answer.ms { if repeated { again.append(ms) } else { first.append(ms) } } else { failures += 1 }
                            try? await Task.sleep(for: pause)
                        }
                    }
                    let missing = await probe.lookup(missingName, server: server)
                    var cdn: [String: String] = [:]
                    for name in FastestDNS.cdnDomains {
                        if let address = await probe.lookup(name, server: server).addresses.first { cdn[name] = address }
                        try? await Task.sleep(for: pause)
                    }
                    let run = DNSResolverRun(id: candidate.id, server: server, firstMs: first, repeatMs: again, queries: queries, failures: failures,
                                             rewritesMissing: missing.status == "NOERROR" && !missing.addresses.isEmpty)
                    return Partial(run: run, cdn: cdn)
                }
            }
            var all: [Partial] = []
            for await partial in group { if let partial { all.append(partial) } }
            return all
        }
        // Each CDN address once, best of two connects, one after another so the timings don't crowd each other.
        var connect: [String: Double] = [:]
        for address in Set(partials.flatMap { $0.cdn.values }).sorted() {
            var best: Double?
            for _ in 0..<2 { if let ms = await probe.connect(address) { best = min(best ?? ms, ms) } }
            if let best { connect[address] = best }
        }
        func times(_ partial: Partial) -> [String: Double] { partial.cdn.compactMapValues { connect[$0] } }
        let network = partials.first { $0.run.id == DNSResolverChoice.network.id }.map(times) ?? [:]
        let order = candidates.map(\.id)
        let resolvers = partials.map { partial -> DNSResolverRun in
            var run = partial.run
            if run.id != DNSResolverChoice.network.id { run.cdnExcessMs = FastestDNS.cdnExcess(candidate: times(partial), network: network) }
            return run
        }.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        return DNSRun(date: date, resolvers: resolvers)
    }
}

/// What the switch reads from the Mac. Tests pass their own.
public protocol DNSSystem: Sendable {
    /// The service's manual DNS servers; empty when it uses the network's own.
    func serviceServers(_ service: String) async -> [String]
    /// The network's own resolvers from DHCP on `interface`.
    func dhcpServers(interface: String) async -> [String]
    /// A profile, an encrypted-DNS app or a DNS proxy decides lookups.
    func managed() async -> Bool
    /// The default route's gateway now.
    func gateway() async -> String?
}

public struct SystemDNS: DNSSystem {
    public init() {}
    public func serviceServers(_ service: String) async -> [String] {
        guard !service.isEmpty, !service.hasPrefix("-") else { return [] }
        return DNSHelperRequest.servers(await CommandRunner.run("/usr/sbin/networksetup", ["-getdnsservers", service], timeout: 4).output)
    }
    public func dhcpServers(interface: String) async -> [String] {
        guard interface.range(of: #"^[a-z]+[0-9]+$"#, options: .regularExpression) != nil else { return [] }
        return Self.dhcpServers(await CommandRunner.run("/usr/sbin/ipconfig", ["getpacket", interface], timeout: 3).output)
    }
    public func managed() async -> Bool { ManagedDNS.present() }
    public func gateway() async -> String? {
        DiagnosticProbe.matches(#"gateway:\s+([^\s]+)"#, in: await CommandRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3).output).first
    }
    /// `ipconfig getpacket en0`: "domain_name_server (ip_mult): {192.168.1.1, 192.168.1.2}".
    public static func dhcpServers(_ output: String) -> [String] {
        guard let list = DiagnosticProbe.matches(#"domain_name_server \(ip_mult\): \{([^}]*)\}"#, in: output).first else { return [] }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter(DNSAddress.valid)
    }
}

/// Changes a service's DNS for the switch. In the app, Kilobat's helper; nil-equivalent `available` false without it.
@MainActor public protocol DNSApplying: AnyObject {
    var available: Bool { get }
    /// Empty `servers` puts automatic DNS back.
    func apply(servers: [String], service: String) async throws
}

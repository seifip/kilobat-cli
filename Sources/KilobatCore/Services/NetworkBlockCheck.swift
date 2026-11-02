import Foundation
import Darwin
import Network
import Security

/// Measures whether a failing host is blocked on this network, only while a failure is being diagnosed: the Mac's own DNS
/// against one DNS-over-HTTPS question to the person's trusted resolver, TLS handshakes to the addresses each gives, the same
/// server named as another site, and one plain-HTTP request. Nothing runs in the background and no list of blocked sites is
/// ever checked. It measures and reports only; it never helps get around a block.
public enum NetworkBlockCheck {
    /// A name under example.com that doesn't exist, for telling a resolver that invents answers from one that doesn't.
    static func madeUpName() -> String { "kilobat-\(UInt32.random(in: 100_000...UInt32.max)).example.com" }
    /// The other name sent to the same server: a site no network has a reason to block.
    static let controlName = "example.com"

    // MARK: Whole checks

    /// The block check for one host. `https` is false for a plain-HTTP target, where no certificate can prove the server.
    public static func run(host: String, https: Bool = true, port: Int = 443, context: BlockContext, resolver: TrustedResolver) async -> NetworkBlock? {
        guard !context.portal, !context.kilobatBlocks, AddressRange.parse(host) == nil, !NetworkBlockRules.internalName(host) else { return nil }
        let measured = await measure(host: host, https: https, port: port, resolver: resolver)
        return NetworkBlockRules.classify(measured, context)
    }

    /// Everything `NetworkBlockRules` reads, measured with as few requests as the answer needs.
    static func measure(host: String, https: Bool, port: Int, resolver: TrustedResolver) async -> BlockMeasurements {
        async let trusted = doh(host, resolver: resolver)
        let system = await systemLookup(host)
        var m = BlockMeasurements(host: host, system: system, trusted: nil, resolver: resolver)
        m.https = https
        let first = system.routable.first(where: { !$0.contains(":") }) ?? system.addresses.first
        if let first, https {
            m.systemHandshake = await handshake(first, port: port, name: host, verify: true)
            if m.systemHandshake?.cut == true {
                async let again = handshake(first, port: port, name: host, verify: true)
                async let control = handshake(first, port: port, name: controlName, verify: false)
                (m.repeatHandshake, m.controlHandshake) = await (again, control)
            }
        }
        m.trusted = await trusted
        guard m.systemHandshake != .verified else { return m }
        // The trusted resolver's own address, when it isn't one the Mac's DNS gave.
        if https, let address = m.trusted?.routable.first(where: { !system.addresses.contains($0) }) {
            m.trustedHandshake = await handshake(address, port: port, name: host, verify: true)
        } else if https, m.trusted?.routable.first != nil { m.trustedHandshake = m.systemHandshake }
        switch system.kind {
        case .nxdomain, .noAnswer: m.systemResolves = await systemLookup(controlName).kind == .addresses
        case .addresses: m.invented = await systemLookup(madeUpName()).addresses
        }
        if system.kind == .addresses, !https || m.systemHandshake != .noConnect {
            (m.plainStatus, m.plainLocation) = await plainHTTP(host)
        }
        return m
    }

    /// The service's own answer, when the doctor's request came back 400, 403 or 451 or was sent to a regional page:
    /// one GET over HTTPS, redirects followed, at most 16 KB read. Nil when nothing in it says "not in your region".
    public static func region(_ url: URL, context: BlockContext, appError: String? = nil, exit: ExitPath.PublicAddress? = nil) async -> NetworkBlock? {
        guard let host = url.host?.lowercased() else { return nil }
        var found: (NetworkBlock.Signal, RegionRefusal.Pattern?)?
        if let appError, let pattern = RegionRefusal.match(appError) { found = (.regionError, pattern) }
        else if url.scheme == "https", let answer = await fetch(url) {
            found = RegionRefusal.signal(status: answer.status, body: answer.body, location: answer.final, verified: true)
        }
        guard let (signal, pattern) = found else { return nil }
        var address = exit
        if address == nil { address = try? await ExitPath.publicAddress() }
        let who = pattern?.company ?? context.service ?? host
        return RegionRefusal.finding(host: host, who: who, signal: signal, pattern: pattern, context: context, exit: address?.country, zone: timeZoneCountry(),
                                     fromApp: appError.flatMap(RegionRefusal.match) != nil)
    }

    /// For `kilobat down`: whether the service's main host connects from here, and when it doesn't, the block check.
    /// One TLS connection to the service's own host; the trusted resolver is asked only if that fails.
    public static func reach(_ service: StatusService, status: ServiceStatus?, place: NetworkPlace, vpn: String?, resolver: TrustedResolver) async -> (reachable: Bool?, block: NetworkBlock?) {
        guard let host = service.endpoints.first ?? service.hosts.first else { return (nil, nil) }
        let system = await systemLookup(host)
        if let address = system.routable.first(where: { !$0.contains(":") }) ?? system.routable.first,
           await handshake(address, port: 443, name: host, verify: true) == .verified { return (true, nil) }
        let context = BlockContext(serviceID: service.id, service: service.name, status: status.flatMap { $0.state == .unknown ? nil : $0.state },
                                   statusSentence: status.map { $0.sentence(notYou: false) }, vpn: vpn, place: place)
        return (false, await run(host: host, context: context, resolver: resolver))
    }

    // MARK: Where the Mac is

    /// The kind of network, from the link and what Kilobat learned about it: a sign-in page seen, or home marked in Devices.
    public static func place(networkKey: String?, directory: URL? = nil) async -> NetworkPlace {
        let path = await ConnectionProbe.currentPath()
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        let signIn = networkKey.map { key in PortalWatch.load(directory: folder).contains { $0.id == key } } ?? false
        let book = (try? Data(contentsOf: folder.appendingPathComponent("devices.json"))).flatMap { try? JSONDecoder().decode(DeviceBook.self, from: $0) }
        let home = networkKey.map { book?.networks[$0]?.home == true } ?? false
        let physical = path.availableInterfaces.first { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
        return NetworkPlace.of(cellular: physical?.type == .cellular, metered: path.isExpensive, signInSeen: signIn, home: home,
                               wifi: physical?.type == .wifi, wired: physical?.type == .wiredEthernet)
    }

    /// The VPN the default route goes through, by name or interface; nil without one.
    public static func vpn() async -> String? {
        let exit = await ExitPath.current()
        return exit.tunnel ? exit.vpnName ?? exit.interface : nil
    }

    /// The ISO country of this Mac's time zone, from macOS's own zone table. Nothing leaves the Mac.
    public static func timeZoneCountry(_ zone: TimeZone = .current) -> String? {
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return nil }
        return RegionRefusal.country(ofTimeZone: zone.identifier, table: table)
    }

    // MARK: Probes

    /// The Mac's own resolver, as apps get it: NXDOMAIN told apart from no answer.
    static func systemLookup(_ host: String) async -> DNSAnswer {
        await Task.detached(priority: .userInitiated) { () -> DNSAnswer in
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            let code = getaddrinfo(host, nil, &hints, &info)
            guard code == 0 else { return DNSAnswer(code == EAI_NONAME ? .nxdomain : .noAnswer) }
            defer { freeaddrinfo(info) }
            var addresses: [String] = [], cursor = info
            while let entry = cursor {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !addresses.contains(address) { addresses.append(address) }
                }
                cursor = entry.pointee.ai_next
            }
            return .addresses(addresses)
        }.value
    }

    /// One A query over DNS-over-HTTPS (RFC 8484) to the trusted resolver, by its address. Nil when it doesn't answer.
    static func doh(_ host: String, resolver: TrustedResolver, timeout: TimeInterval = 4) async -> DNSAnswer? {
        var request = URLRequest(url: resolver.url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = ConnectionProbe.dnsQuery(host, id: 0)
        let session = URLSession(configuration: ephemeral(timeout))
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseAnswer(data)
    }

    /// A DNS reply's code and its A records: NXDOMAIN, no usable answer (SERVFAIL, REFUSED, none), or addresses.
    static func parseAnswer(_ data: Data) -> DNSAnswer? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[2] & 0x80 != 0 else { return nil }
        switch bytes[3] & 0x0f {
        case 0: return ConnectionProbe.dnsAnswers(data, id: UInt16(bytes[0]) << 8 | UInt16(bytes[1])).map(DNSAnswer.addresses)
        case 3: return DNSAnswer(.nxdomain)
        default: return DNSAnswer(.noAnswer)
        }
    }

    /// TCP to the address, then TLS sent with `name`. `verify` checks the certificate against `name`; without it any
    /// certificate is accepted, since the question is only whether the server answers.
    static func handshake(_ address: String, port: Int, name: String, verify: Bool, timeout: Double = 5) async -> Handshake {
        guard await ConnectionProbe.open(host: address, port: port, timeout: timeout).outcome == .connected else { return .noConnect }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .noConnect }
        let tls = NWProtocolTLS.Options(), queue = DispatchQueue(label: "co.seifi.kilobat.block.tls"), state = HandshakeState()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, name)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let ref = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(ref, SecPolicyCreateSSL(true, name as CFString))
            state.trusted = SecTrustEvaluateWithError(ref, nil)
            // Finish either way: an untrusted certificate is an answer, kept apart from a handshake that died.
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = Int(timeout)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ result: Handshake) {
                guard state.claim() else { return }
                connection.stateUpdateHandler = nil; connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready: finish(!verify || state.trusted ? .verified : .untrusted)
                case .failed(let error), .waiting(let error): finish(classify(error))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.timedOut) }
            connection.start(queue: queue)
        }
    }

    /// A reset, or the connection closed under the handshake, is a cut; any other TLS error is the server answering with an alert.
    static func classify(_ error: NWError) -> Handshake {
        switch error {
        case .posix(let code) where [.ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN].contains(code): .reset
        case .posix(.ETIMEDOUT): .timedOut
        case .posix: .noConnect
        // errSSLClosedAbort and errSSLClosedGraceful: the connection closed before the server said anything.
        case .tls(let status) where status == -9806 || status == -9805: .reset
        case .tls: .alert
        default: .noConnect
        }
    }

    /// One plain-HTTP GET, its redirect not followed: block pages answer here with 451 or a redirect to a notice.
    static func plainHTTP(_ host: String) async -> (Int?, String?) {
        guard let url = URL(string: "http://\(host)/") else { return (nil, nil) }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: ephemeral(4))
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request, delegate: StopRedirects()), let http = response as? HTTPURLResponse else { return (nil, nil) }
        return (http.statusCode, http.value(forHTTPHeaderField: "Location"))
    }

    /// One HTTPS GET with redirects followed, the system validating the certificate; the first 16 KB of the body.
    static func fetch(_ url: URL) async -> (status: Int, body: String, final: String?)? {
        let session = URLSession(configuration: ephemeral(8))
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url), let http = response as? HTTPURLResponse else { return nil }
        var body = Data()
        do { for try await byte in bytes { body.append(byte); if body.count >= 16_384 { break } } } catch {}
        return (http.statusCode, String(decoding: body, as: UTF8.self), http.url?.absoluteString)
    }

    static func ephemeral(_ timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout + 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        return configuration
    }

    private final class HandshakeState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var _trusted = false
        var trusted: Bool { get { lock.withLock { _trusted } } set { lock.withLock { _trusted = newValue } } }
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}

/// Stops at the first answer, so a block page's redirect is read rather than followed.
private final class StopRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

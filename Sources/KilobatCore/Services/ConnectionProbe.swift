import AppKit
import Darwin
import Network

/// The connection doctor's own checks, made in-process with Network.framework and URLSession. Shelling out to
/// `nc` or `curl` would let a strict Kilobat profile block or hold the doctor like any other app.
enum ConnectionProbe {
    /// The interface a connection leaves through, in words.
    struct Link: Sendable, Equatable {
        let name: String
        let kind: String
        let expensive: Bool
        var vpn: Bool { kind == "VPN" }
        var label: String { "\(kind) (\(name)\(expensive ? ", metered" : ""))" }

        init(name: String, kind: String, expensive: Bool = false) { self.name = name; self.kind = kind; self.expensive = expensive }
        init(_ interface: NWInterface, expensive: Bool) {
            let vpn = ["utun", "ipsec", "ppp"].contains { interface.name.hasPrefix($0) }
            let kind = switch interface.type {
            case .wifi: "Wi-Fi"
            case .wiredEthernet: "Ethernet"
            case .cellular: "Cellular"
            case .loopback: "this Mac"
            default: vpn ? "VPN" : interface.name.hasPrefix("lo") ? "this Mac" : "Other"
            }
            self.init(name: interface.name, kind: kind, expensive: expensive)
        }
    }

    /// One connection attempt.
    struct Attempt: Sendable, Equatable {
        enum Outcome: Sendable, Equatable { case connected, refused, timedOut, failed(String), tlsFailed(String), noAddress }
        var outcome: Outcome
        var ms = 0
        var address: String?
        /// The Mac's own address on that connection.
        var source: String?
        var link: Link?
        var dnsProtocol: NWConnection.EstablishmentReport.Resolution.DNSProtocol?
    }

    /// The Mac's default path, as macOS sees it now.
    static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil; monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "co.seifi.kilobat.doctor.path"))
        }
    }

    /// Opens one TCP (or TLS) connection and closes it. `version` and `interface` pin the IP family and the interface;
    /// proxies are skipped, so this is the direct path.
    static func open(host: String, port: Int, version: NWProtocolIP.Options.Version = .any, tls: Bool = false,
                     interface: NWInterface? = nil, timeout: Double = 5) async -> Attempt {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let queue = DispatchQueue(label: "co.seifi.kilobat.doctor.probe"), started = Date(), once = Once(), trustError = Once()
        let secure = tls ? NWProtocolTLS.Options() : nil
        if let secure {
            // The system's own evaluation, kept for its message: "certificate name does not match" says more than an OSStatus.
            sec_protocol_options_set_verify_block(secure.securityProtocolOptions, { _, trust, complete in
                var error: CFError?
                let trusted = SecTrustEvaluateWithError(sec_trust_copy_ref(trust).takeRetainedValue(), &error)
                if let error { trustError.message = CFErrorCopyDescription(error) as String }
                complete(trusted)
            }, queue)
        }
        let parameters = NWParameters(tls: secure, tcp: tcp)
        parameters.preferNoProxies = true
        if let interface { parameters.requiredInterface = interface }
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = version
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return Attempt(outcome: .failed("invalid port")) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ outcome: Attempt.Outcome) {
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                let path = connection.currentPath
                let attempt = Attempt(outcome: outcome, ms: Int(Date().timeIntervalSince(started) * 1000),
                                      address: path?.remoteEndpoint.flatMap(address), source: path?.localEndpoint.flatMap(address), link: path.flatMap { path in path.availableInterfaces.first.map { Link($0, expensive: path.isExpensive) } })
                guard outcome == .connected else { connection.cancel(); continuation.resume(returning: attempt); return }
                connection.requestEstablishmentReport(queue: queue) { report in
                    connection.cancel()
                    var detailed = attempt
                    detailed.dnsProtocol = report?.resolutions.first?.dnsProtocol
                    // A TLS attempt reports its handshake, not the TCP connect before it.
                    if tls, let handshake = report?.handshakes.first(where: { $0.definition.name == "tls" }) { detailed.ms = Int(handshake.handshakeDuration * 1000) }
                    continuation.resume(returning: detailed)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.connected)
                case .waiting(let error), .failed(let error): finish(trustError.message.map { .tlsFailed($0) } ?? outcome(error))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.timedOut) }
            connection.start(queue: queue)
        }
    }

    static func outcome(_ error: NWError) -> Attempt.Outcome {
        switch error {
        case .posix(.ECONNREFUSED): .refused
        case .posix(.ETIMEDOUT): .timedOut
        case .posix(let code): .failed(String(cString: strerror(code.rawValue)).lowercased())
        case .dns(let code) where code == -65554: .noAddress
        case .dns(let code): .failed("DNS error \(code)")
        case .tls(let status): .tlsFailed((SecCopyErrorMessageString(status, nil) as String?).map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "error \(status)")
        default: .failed(error.debugDescription)
        }
    }

    static func address(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)".components(separatedBy: "%").first
        case .name(let name, _): name
        @unknown default: nil
        }
    }

    // MARK: HTTP

    enum Answer: Sendable, Equatable { case status(Int), secureFailed(String), closed(String), failed(String) }

    /// One request of a redirect chain. `head` is HEAD's answer when the server refused it and a one-byte GET followed.
    struct Hop: Sendable, Equatable {
        var url: URL
        var answer: Answer
        var head: Answer?
        var location: URL?
        var method: String { head == nil ? "HEAD" : "GET" }
    }

    /// The exact URL, query included, with redirects followed one at a time so each hop's host and answer is known.
    /// Through the system's own path, proxies included; `proxy` sends it through that proxy instead, as a tool reading HTTPS_PROXY would.
    static func fetch(_ url: URL, through proxy: String? = nil, redirects: Int = 5) async -> [Hop] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        if let proxy, let endpoint = endpoint(proxy) {
            let kinds = proxy.lowercased().hasPrefix("socks") ? ["SOCKS"] : ["HTTP", "HTTPS"]
            configuration.connectionProxyDictionary = kinds.reduce(into: [AnyHashable: Any]()) { settings, kind in
                settings[kind + "Enable"] = 1; settings[kind + "Proxy"] = endpoint.host; settings[kind + "Port"] = endpoint.port
            }
        }
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var hops: [Hop] = [], next = url
        while hops.count <= redirects {
            var hop = await send(next, method: "HEAD", in: session)
            if refusesHead(hop.answer) {
                let get = await send(next, method: "GET", in: session)
                hop = Hop(url: next, answer: get.answer, head: hop.answer, location: get.location)
            }
            hops.append(hop)
            guard let location = hop.location else { break }
            next = location
        }
        return hops
    }

    /// Servers that don't take HEAD answer 403, 405 or 501, or close the connection. A pre-signed download URL signs its method, so HEAD gets 403.
    static func refusesHead(_ answer: Answer) -> Bool {
        switch answer {
        case .status(let code): [403, 405, 501].contains(code)
        case .closed: true
        default: false
        }
    }

    static func send(_ url: URL, method: String, in session: URLSession) async -> Hop {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // One byte at most, and the task stops once the headers arrive in case the server ignores the range.
        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            let http = response as? HTTPURLResponse, code = http?.statusCode ?? 0
            let location = (300..<400).contains(code) && code != 304 ? http?.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } : nil
            return Hop(url: url, answer: .status(code), location: location.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil })
        } catch let error as URLError {
            let tls: Set<URLError.Code> = [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                                           .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired]
            let closed: Set<URLError.Code> = [.networkConnectionLost, .badServerResponse, .cannotParseResponse, .zeroByteResource]
            let message = error.localizedDescription
            return Hop(url: url, answer: tls.contains(error.code) ? .secureFailed(message) : closed.contains(error.code) ? .closed(message) : .failed(message))
        } catch { return Hop(url: url, answer: .failed(error.localizedDescription)) }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// A URL as it may be shown: no user name or password, and every query value replaced, so a signed or token URL can't leak.
    /// Parameter names stay, since they tell what kind of URL it is.
    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "" }
        let query = components.percentEncodedQuery
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        guard let query, !query.isEmpty else { return components.string ?? "" }
        return (components.string ?? "") + "?" + query.split(separator: "&", omittingEmptySubsequences: false).map { item in
            item.isEmpty ? "" : item.firstIndex(of: "=").map { item[..<$0] + "=[redacted]" } ?? "[redacted]"
        }.joined(separator: "&")
    }

    /// Text with the query and password of these URLs taken out, for messages that might quote one.
    static func scrubbed(_ text: String, _ urls: [URL]) -> String {
        urls.reduce(text) { text, url in
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return text }
            let shown = redacted(url), query = shown.firstIndex(of: "?").map { String(shown[shown.index(after: $0)...]) } ?? ""
            return [(components.percentEncodedQuery, query), (components.query, query), (components.password, "[redacted]")].reduce(text) { text, pair in
                guard let secret = pair.0, !secret.isEmpty else { return text }
                return text.replacingOccurrences(of: secret, with: pair.1)
            }
        }
    }

    // MARK: Proxies

    /// The proxy the system picks for one URL, after running its PAC file when one is set.
    struct SystemProxy: Sendable, Equatable {
        var proxy: String?
        var pac: String?
        var pacFailed = false
    }

    static func systemProxy(for url: URL) async -> SystemProxy {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let entries = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] else { return SystemProxy() }
        for entry in entries {
            let type = entry[kCFProxyTypeKey as String] as? String
            if type == kCFProxyTypeAutoConfigurationURL as String {
                guard let pac = entry[kCFProxyAutoConfigurationURLKey as String] as? URL else { continue }
                guard let script = await download(pac) else { return SystemProxy(pac: redacted(pac.absoluteString), pacFailed: true) }
                return SystemProxy(proxy: await evaluate(script, url), pac: redacted(pac.absoluteString))
            }
            if type == kCFProxyTypeAutoConfigurationJavaScript as String {
                guard let script = entry[kCFProxyAutoConfigurationJavaScriptKey as String] as? String else { continue }
                return SystemProxy(proxy: await evaluate(script, url), pac: "set as a script")
            }
            return SystemProxy(proxy: proxy(entry))
        }
        return SystemProxy()
    }

    /// "host:port" for an HTTP(S) or SOCKS proxy entry, nil for a direct connection.
    static func proxy(_ entry: [String: Any]) -> String? {
        guard let type = entry[kCFProxyTypeKey as String] as? String, type != kCFProxyTypeNone as String,
              let host = entry[kCFProxyHostNameKey as String] as? String else { return nil }
        let port = (entry[kCFProxyPortNumberKey as String] as? NSNumber).map { ":\($0)" } ?? ""
        return (type == kCFProxyTypeSOCKS as String ? "SOCKS " : "") + host + port
    }

    static func evaluate(_ script: String, _ url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            var error: Unmanaged<CFError>?
            guard let result = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString, url as CFURL, &error)?.takeRetainedValue() as? [[String: Any]] else { return nil }
            return result.first.flatMap(proxy)
        }.value
    }

    static func download(_ url: URL) async -> String? {
        if url.isFileURL { return try? String(contentsOf: url, encoding: .utf8) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A proxy URL without its user name and password.
    static func redacted(_ proxy: String) -> String {
        let start = proxy.range(of: "://")?.upperBound ?? proxy.startIndex
        let authority = proxy[start...].prefix { !"/?#".contains($0) }
        guard let at = authority.lastIndex(of: "@") else { return proxy }
        return String(proxy[..<start]) + String(proxy[proxy.index(after: at)...])
    }

    /// Host and port of a proxy URL, with the scheme's default port.
    static func endpoint(_ proxy: String) -> (host: String, port: Int)? {
        guard let components = URLComponents(string: proxy.contains("://") ? proxy : "http://" + proxy), let host = components.host, !host.isEmpty else { return nil }
        let scheme = components.scheme?.lowercased() ?? "http"
        return (host, components.port ?? (scheme.hasPrefix("socks") ? 1080 : scheme == "https" ? 443 : 80))
    }

    /// The proxy variable a process's environment applies to a URL, as curl, Node and most CLI tools read them.
    struct EnvironmentProxy: Sendable, Equatable {
        let variable: String
        let value: String
        /// NO_PROXY matches this host, so the tool connects directly.
        var bypassed: Bool { variable.lowercased() == "no_proxy" }
    }

    static func environmentProxy(_ environment: [String: String], for url: URL) -> EnvironmentProxy? {
        let host = url.host?.lowercased() ?? ""
        let keys = url.scheme == "http" ? ["http_proxy", "HTTP_PROXY"] : ["HTTPS_PROXY", "https_proxy"]
        guard let variable = (keys + ["ALL_PROXY", "all_proxy"]).first(where: { environment[$0]?.isEmpty == false }) else { return nil }
        for key in ["NO_PROXY", "no_proxy"] {
            guard let list = environment[key] else { continue }
            for entry in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                let domain = (entry.hasPrefix("*.") ? String(entry.dropFirst(2)) : entry.hasPrefix(".") ? String(entry.dropFirst()) : entry)
                    .components(separatedBy: ":").first ?? ""
                if entry == "*" || (!domain.isEmpty && (host == domain || host.hasSuffix("." + domain))) { return EnvironmentProxy(variable: key, value: entry) }
            }
        }
        return EnvironmentProxy(variable: variable, value: redacted(environment[variable] ?? ""))
    }

    enum Environment: Sendable, Equatable { case notRunning, unreadable, found(name: String, values: [String: String]) }

    /// The environment of a running app or process of this user. Another user's processes can't be read, and that's fine.
    static func environment(of app: String) -> Environment {
        let (name, pids) = processes(of: app)
        guard !pids.isEmpty else { return .notRunning }
        let readable = pids.prefix(32).compactMap(environment(pid:))
        // Several copies may run; one that sets a proxy is the one worth reporting.
        guard let values = readable.first(where: { values in proxyKeys.contains { values[$0] != nil } }) ?? readable.first else { return .unreadable }
        return .found(name: name, values: values)
    }

    /// The app's name and its running processes: a bundle ID's running copies, or every process of that executable for process:<name>.
    static func processes(of app: String) -> (name: String, pids: [Int32]) {
        guard app.hasPrefix("process:") else {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app)
            return (running.first?.localizedName ?? app, running.map(\.processIdentifier))
        }
        let name = String(app.dropFirst(8))
        var all = [Int32](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<Int32>.size)))
        return (name, all.prefix(max(0, count)).filter { pid in
            guard pid > 0, let executable = executable(pid) else { return false }
            return executable == name || (name.count >= 15 && executable.hasPrefix(name))
        })
    }

    /// The app as installed: its name and bundle version, from the running copy or else the installed one. A process:<name> has no bundle to read.
    static func client(_ app: String) -> DoctorClient {
        guard !app.hasPrefix("process:") else { return DoctorClient(id: app, name: String(app.dropFirst(8)), version: nil) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first
        let info = (running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)).flatMap { Bundle(url: $0)?.infoDictionary }
        let name = running?.localizedName ?? info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? app
        return DoctorClient(id: app, name: name, version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String)
    }

    static let proxyKeys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"]

    static func executable(_ pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent
    }

    static func environment(pid: Int32) -> [String: String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // macOS hides the environment of some processes, Apple's own tools among them; an empty one means hidden.
        return processEnvironment(Array(buffer.prefix(size))).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Parses KERN_PROCARGS2: argc, the executable path and its padding, argc arguments, then the environment up to an empty string.
    static func processEnvironment(_ buffer: [UInt8]) -> [String: String]? {
        guard buffer.count >= 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        func next() -> String? {
            guard index < buffer.count else { return nil }
            let start = index
            while index < buffer.count && buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        guard argc >= 0, next() != nil else { return nil }
        while index < buffer.count && buffer[index] == 0 { index += 1 }
        for _ in 0..<argc { guard next() != nil else { return nil } }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    // MARK: DNS

    /// The resolver macOS sends a host to. `domain` is set for a split-DNS resolver, the kind a VPN, Tailscale or NetBird adds.
    struct Resolver: Sendable, Equatable {
        let server: String
        var domain: String?
        var description: String { server + (domain.map { ", the private resolver for \($0)" } ?? "") }
    }

    /// A split-DNS resolver whose domain matches the host, the longest match first, else the default one.
    static func resolver(for host: String, in scutil: String) -> Resolver? {
        let host = host.lowercased(), main = scutil.components(separatedBy: "DNS configuration (for scoped queries)").first ?? scutil
        var best: Resolver?, fallback: Resolver?
        for block in main.components(separatedBy: "resolver #").dropFirst() {
            guard !block.contains("mdns"), let server = DiagnosticProbe.matches(#"nameserver\[0\] : (\S+)"#, in: block).first else { continue }
            if let domain = DiagnosticProbe.matches(#"(?m)^\s*domain\s+: (\S+)"#, in: block).first?.lowercased() {
                if (host == domain || host.hasSuffix("." + domain)) && domain.count > best?.domain?.count ?? -1 { best = Resolver(server: server, domain: domain) }
            } else if fallback == nil { fallback = Resolver(server: server) }
        }
        return best ?? fallback
    }

    /// Asks 1.1.1.1 directly for A records, bypassing the Mac's resolver. Nil when it doesn't answer.
    static func directLookup(_ host: String, server: String = "1.1.1.1") async -> [String]? {
        let id = UInt16.random(in: 1...UInt16.max), parameters = NWParameters.udp
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: parameters)
        let queue = DispatchQueue(label: "co.seifi.kilobat.doctor.dns"), once = Once()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ answer: [String]?) {
                guard once.claim() else { return }
                connection.cancel(); continuation.resume(returning: answer)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: dnsQuery(host, id: id), completion: .contentProcessed { _ in })
                    connection.receiveMessage { data, _, _, _ in finish(data.flatMap { dnsAnswers($0, id: id) }) }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
            connection.start(queue: queue)
        }
    }

    static func dnsQuery(_ host: String, id: UInt16) -> Data {
        var data = Data([UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            data.append(UInt8(bytes.count)); data.append(contentsOf: bytes)
        }
        data.append(contentsOf: [0, 0, 1, 0, 1])
        return data
    }

    /// The IPv4 addresses in a DNS answer; empty when the name doesn't exist, nil when it isn't an answer to `id`.
    static func dnsAnswers(_ data: Data, id: UInt16) -> [String]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id, bytes[2] & 0x80 != 0 else { return nil }
        guard bytes[3] & 0x0f == 0 else { return [] }
        var index = 12
        func skipName() -> Bool {
            while index < bytes.count {
                let length = Int(bytes[index])
                if length == 0 { index += 1; return true }
                if length & 0xc0 == 0xc0 { index += 2; return index <= bytes.count }
                index += length + 1
            }
            return false
        }
        for _ in 0..<(Int(bytes[4]) << 8 | Int(bytes[5])) { guard skipName() else { return nil }; index += 4 }
        var addresses: [String] = []
        for _ in 0..<(Int(bytes[6]) << 8 | Int(bytes[7])) {
            guard skipName(), index + 10 <= bytes.count else { break }
            let type = Int(bytes[index]) << 8 | Int(bytes[index + 1]), length = Int(bytes[index + 8]) << 8 | Int(bytes[index + 9])
            index += 10
            guard index + length <= bytes.count else { break }
            if type == 1 && length == 4 { addresses.append(bytes[index..<index + 4].map(String.init).joined(separator: ".")) }
            index += length
        }
        return addresses
    }

    // MARK: Interfaces

    /// IPv4 addresses on every interface, for spotting one left behind after a network change.
    static func interfaceAddresses() -> [(name: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = [], cursor = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: entry.pointee.ifa_name), String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        return found
    }

    /// Network ports (en…) that still hold an address while macOS no longer offers them, such as a tether you unplugged.
    static func leftovers(_ addresses: [(name: String, address: String)], active: Set<String>) -> [String] {
        addresses.filter { $0.name.hasPrefix("en") && !active.contains($0.name) && !$0.address.hasPrefix("169.254.") }.map { "\($0.name) (\($0.address))" }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var text: String?
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        var message: String? {
            get { lock.withLock { text } }
            set { lock.withLock { text = newValue } }
        }
    }
}

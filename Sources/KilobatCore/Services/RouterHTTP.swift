import CFNetwork
import CryptoKit
import Darwin
import Foundation
import Security

/// What went wrong talking to the router, in words the setup sheet and the CLI can show.
public enum RouterAPIError: Error, Equatable, Sendable, LocalizedError {
    /// The address isn't on the local network (or resolves outside it): credentials never go there.
    case notLocal
    /// The router turned the user or password down.
    case unauthorized
    /// Signed in, but the user lacks the right for this, as FRITZ!Box answers 606.
    case notAllowed(String)
    /// Too many tries; the router waits before it answers again (FRITZ!Box sends 503).
    case busy
    /// The router's own certificate isn't the one confirmed before, or none was confirmed yet. `fingerprint` is SHA-256 of the certificate.
    case certificate(fingerprint: String, changed: Bool)
    case unreachable(String)
    /// It answered, but not as this kind of router would.
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .notLocal: String(localized: "That address isn’t on your local network. Kilobat only signs in to a router on your home network.", comment: "Router connection error")
        case .unauthorized: String(localized: "The router turned down that user or password.", comment: "Router connection error")
        case .notAllowed(let what): String(localized: "Signed in, but this user may not read \(what). Give it more rights on the router.", comment: "Router connection error; the argument is what the router refused, such as “the device list”")
        case .busy: String(localized: "The router is refusing sign-ins for a moment after several tries. Wait a minute, then try again.", comment: "Router connection error")
        case .certificate(_, let changed): changed
            ? String(localized: "The router’s certificate changed since you confirmed it. Check it on the router before you trust the new one.", comment: "Router connection error")
            : String(localized: "The router uses its own certificate. Compare its fingerprint with the router’s settings, then trust it.", comment: "Router connection: a self-signed certificate needs the user's confirmation")
        case .unreachable(let detail): String(localized: "Couldn’t reach the router: \(detail)", comment: "Router connection error; the argument is the system's reason")
        case .unexpected(let detail): String(localized: "The router answered, but not as expected: \(detail)", comment: "Router connection error; the argument is a short technical detail")
        }
    }
}

/// Which addresses Kilobat signs in to: private and link-local IPv4 only. A host name is resolved once, when the
/// router is connected, and every request then goes to that address, so a later DNS answer can't redirect them.
public enum RouterAddress {
    /// 10/8, 172.16/12, 192.168/16 and 169.254/16; 127/8 only when `loopback` (tests' local servers).
    public static func isLocal(_ host: String, loopback: Bool = false) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard parts.count == 4, values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (values[0], values[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, let b): return (16...31).contains(b)
        case (127, _): return loopback
        default: return false
        }
    }

    /// The URL with its host replaced by a local IPv4 address: the host itself when it is one, else what it resolves
    /// to, provided every IPv4 answer is local. Credentials and paths in the URL are refused.
    public static func resolve(_ text: String, defaultScheme: String = "http", loopback: Bool = false) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = defaultScheme + "://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { throw RouterAPIError.notLocal }
        parts.scheme = scheme; parts.path = ""; parts.query = nil; parts.fragment = nil
        if isLocal(host, loopback: loopback) { return parts.url! }
        let answers = lookup(host)
        guard let first = answers.first, answers.allSatisfy({ isLocal($0, loopback: loopback) }) else { throw RouterAPIError.notLocal }
        parts.host = first
        return parts.url!
    }

    static func lookup(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = [], node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr, current.pointee.ai_family == AF_INET {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                    var addr = inet.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
                addresses.append(String(cString: buffer))
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}

/// One HTTP request to the router and its answer. The app's transport pins the router's certificate; tests use a local server.
public protocol RouterTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession for one router: no cookies, no cached credentials, no redirects (a redirect could carry a header
/// elsewhere), short timeouts, local addresses only, and HTTPS accepted only with the certificate the person confirmed.
public final class RouterSession: RouterTransport, @unchecked Sendable {
    private let trust: RouterTrust
    private let session: URLSession
    private let loopback: Bool
    private var pin: String? { trust.pin }
    private var trustAny: Bool { trust.trustAny }

    /// `pin` is the confirmed certificate's SHA-256; `trustAny` only for detection probes, which never carry credentials.
    public init(pin: String?, trustAny: Bool = false, loopback: Bool = false) {
        trust = RouterTrust(pin: pin?.lowercased(), trustAny: trustAny); self.loopback = loopback
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0, kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0, kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0,
        ]
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    /// The certificate the router showed on the last HTTPS request.
    public var fingerprint: String? { trust.seen }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let host = request.url?.host, RouterAddress.isLocal(host, loopback: loopback) else { throw RouterAPIError.notLocal }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RouterAPIError.unexpected("not HTTP") }
            return (data, http)
        } catch let error as URLError {
            if request.url?.scheme == "https", let seen = fingerprint, seen != pin, !trustAny,
               [.cancelled, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(error.code) {
                throw RouterAPIError.certificate(fingerprint: seen, changed: pin != nil)
            }
            throw RouterAPIError.unreachable(error.localizedDescription)
        }
    }
}

/// The session's delegate: accepts the router's certificate only when it is the pinned one, and follows no redirects.
final class RouterTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pin: String?
    let trustAny: Bool
    private let lock = NSLock()
    private var last: String?
    init(pin: String?, trustAny: Bool) { self.pin = pin; self.trustAny = trustAny }
    var seen: String? { lock.withLock { last } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else {
            // Basic and digest are answered in headers by the caller, never from a store; the 401 goes back to it as it came.
            completionHandler(.rejectProtectionSpace, nil); return
        }
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let print = leaf.map { CertificatePin.fingerprint(SecCertificateCopyData($0) as Data) }
        lock.withLock { last = print }
        if trustAny || (print != nil && print == pin) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The certificate fingerprint the person confirms, as routers show it: SHA-256 of the DER certificate.
public enum CertificatePin {
    public static func fingerprint(_ der: Data) -> String { SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined() }
    /// "AB:CD:…" in pairs, as FRITZ!Box, RouterOS and openssl print it.
    public static func display(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 2).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            return fingerprint[start..<fingerprint.index(start, offsetBy: 2, limitedBy: fingerprint.endIndex)!].uppercased()
        }.joined(separator: ":")
    }
}

/// HTTP digest authentication (RFC 7616 with MD5, as TR-064 uses it): the challenge from a 401, and the header for each request.
public struct DigestChallenge: Equatable, Sendable {
    public var realm: String
    public var nonce: String
    public var qop: String?
    public var opaque: String?
    public var algorithm: String?
    public var stale = false
    /// Requests answered with this nonce so far.
    public var count = 0

    /// From a WWW-Authenticate header; nil unless it's Digest with a realm and a nonce.
    public init?(header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest ") else { return nil }
        let params = Self.parameters(String(trimmed.dropFirst(7)))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        self.realm = realm; self.nonce = nonce; opaque = params["opaque"]; algorithm = params["algorithm"]
        qop = params["qop"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.flatMap { $0.contains("auth") ? "auth" : $0.first }
        stale = params["stale"]?.lowercased() == "true"
    }

    static func parameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:], index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " || text[index] == "," { index = text.index(after: index) }
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let key = text[index..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            index = text.index(after: equals)
            var value = ""
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex { index = text.index(after: index) }
                    value.append(text[index]); index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let end = text[index...].firstIndex(of: ",") ?? text.endIndex
                value = text[index..<end].trimmingCharacters(in: .whitespaces); index = end
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    static func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The response hash; `cnonce` is random in use and fixed in tests.
    public static func response(user: String, password: String, realm: String, nonce: String, method: String, uri: String,
                                qop: String?, nc: String, cnonce: String) -> String {
        let ha1 = md5("\(user):\(realm):\(password)"), ha2 = md5("\(method):\(uri)")
        guard let qop else { return md5("\(ha1):\(nonce):\(ha2)") }
        return md5("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)")
    }

    /// The Authorization header for the next request, counting it.
    public mutating func authorization(user: String, password: String, method: String, uri: String, cnonce: String = Self.cnonce()) -> String {
        count += 1
        let nc = String(format: "%08x", count)
        let hash = Self.response(user: user, password: password, realm: realm, nonce: nonce, method: method, uri: uri, qop: qop, nc: nc, cnonce: cnonce)
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var parts = ["username=\(quote(user))", "realm=\(quote(realm))", "nonce=\(quote(nonce))", "uri=\(quote(uri))", "response=\(quote(hash))"]
        if let algorithm { parts.append("algorithm=\(algorithm)") }
        if let qop { parts += ["qop=\(qop)", "nc=\(nc)", "cnonce=\(quote(cnonce))"] }
        if let opaque { parts.append("opaque=\(quote(opaque))") }
        return "Digest " + parts.joined(separator: ", ")
    }

    public static func cnonce() -> String { (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
}

/// Small shared helpers for the router clients.
enum RouterHTTP {
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 8
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    static func basic(_ user: String, _ password: String) -> String { "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() }
    /// Answers are small; anything larger isn't the router's JSON or XML.
    static let maxBody = 4_000_000
    static func check(_ data: Data) throws { if data.count > maxBody { throw RouterAPIError.unexpected("answer too large") } }
    static func json(_ data: Data) throws -> Any {
        try check(data)
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw RouterAPIError.unexpected("not JSON") }
    }
    /// A number the router may send as a number or a string, such as RouterOS's "12345".
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    static func bytes(_ value: Any?) -> UInt64? { number(value).flatMap { $0 >= 0 && $0 < 1.8e19 ? UInt64($0) : nil } }
}

import Foundation

/// Reads a router and returns what it says now.
public protocol RouterReader: Sendable {
    func poll() async throws -> RouterPoll
}

public enum RouterReaders {
    /// The reader for a saved connection, with its secret from the Keychain.
    public static func make(_ connection: RouterConnection, secret: String, transport: RouterTransport) throws -> RouterReader {
        guard let base = connection.base else { throw RouterAPIError.notLocal }
        switch connection.kind {
        case .fritzbox: return FritzBox(base: base, user: connection.user ?? "", password: secret, transport: transport)
        case .unifi:
            return UniFiConsole(base: base, auth: connection.auth == .account ? .account(user: connection.user ?? "", password: secret) : .apiKey(secret),
                                site: connection.site, siteName: connection.siteName, transport: transport)
        case .mikrotik: return RouterOSREST(base: base, user: connection.user ?? "", password: secret, transport: transport)
        case .openwrt: return OpenWrtUbus(base: base, user: connection.user ?? "root", password: secret, transport: transport)
        case .upnp: throw RouterAPIError.unexpected("UPnP needs no sign-in")
        }
    }
}

/// AVM's TR-064 on a FRITZ!Box: SOAP over HTTP on port 49000, or HTTPS on the port GetSecurityPort names (49443),
/// with HTTP digest authentication (MD5). Documented in FRITZ!'s "TR-064 First Steps" and per-service PDFs.
///
/// TR-064 has no per-device traffic. It gives the device list (Hosts), the line's byte counters and current rate
/// (WANCommonInterfaceConfig) and the uptime (DeviceInfo). Rights, from "First Steps" 6.1: DeviceInfo:GetInfo, the
/// byte counters and the online monitor need FRITZ!Box Settings (C); the host list path needs C, App or Phone;
/// GetGenericHostEntry and GetCommonLinkProperties need none or any. A limited user still gets the device list and the
/// line's rate; whatever it may not read is skipped and noted.
public actor FritzBox: RouterReader {
    public static let deviceInfo = "urn:dslforum-org:service:DeviceInfo:1"
    public static let hosts = "urn:dslforum-org:service:Hosts:1"
    public static let wan = "urn:dslforum-org:service:WANCommonInterfaceConfig:1"
    static let defaultControls = [deviceInfo: "/upnp/control/deviceinfo", hosts: "/upnp/control/hosts", wan: "/upnp/control/wancommonifconfig1",
                                  "urn:dslforum-org:service:UserInterface:1": "/upnp/control/userif"]
    /// GetGenericHostEntry one by one is slow; past this many the list is cut.
    static let maxHosts = 200

    let base: URL
    let user: String
    let password: String
    let transport: RouterTransport
    private var challenge: DigestChallenge?
    private var controls: [String: String]?

    public init(base: URL, user: String, password: String, transport: RouterTransport) {
        self.base = base; self.user = user; self.password = password; self.transport = transport
    }

    /// The box's HTTPS port; asked over plain HTTP without signing in, as FRITZ! documents.
    public func securityPort() async throws -> Int? {
        let values = try await call(Self.deviceInfo, "GetSecurityPort", authenticate: false)
        return values["NewSecurityPort"].flatMap { Int($0) }
    }

    public func poll() async throws -> RouterPoll {
        limited = false
        let info = try await optional(Self.deviceInfo, "GetInfo")
        var clients: [RouterClient]
        do { clients = try await hostList() }
        catch RouterAPIError.notAllowed { limited = true; clients = try await genericHosts() }
        catch RouterAPIError.unexpected { clients = try await genericHosts() }
        let received = try await optional(Self.wan, "GetTotalBytesReceived")?["NewTotalBytesReceived"].flatMap { UInt64($0) }
        let sent = try await optional(Self.wan, "GetTotalBytesSent")?["NewTotalBytesSent"].flatMap { UInt64($0) }
        var rates = try await optional(Self.wan, "X_AVM-DE_GetOnlineMonitor", [("NewSyncGroupIndex", "0")]).map(TR064.monitorRates)
        if rates?.down == nil { rates = try await optional(Self.wan, "GetCommonLinkProperties").map(TR064.utilization) }
        let wan = RouterWAN(down: received, up: sent, downRate: rates?.down, upRate: rates?.up, bits: 32)
        var poll = RouterPoll(clients: clients, wan: wan, uptime: info?["NewUpTime"].flatMap { Double($0) },
                              model: info?["NewModelName"], firmware: info?["NewSoftwareVersion"], perDevice: false, missing: limited ? ["rights"] : [])
        poll.update = try await firmware(installed: info?["NewSoftwareVersion"])
        return poll
    }

    /// UserInterface:GetInfo, which needs no rights: whether the box itself found newer FRITZ!OS, and which. Asked
    /// every six hours. Only GetInfo and X_AVM-DE_GetInfo are ever called: never CheckUpdate or DoUpdate.
    func firmware(installed: String?) async throws -> RouterFirmware? {
        if let cached = update, Date().timeIntervalSince(cached.date) < 6 * 3600 { return cached.firmware }
        guard let values = try await optional(Self.userInterface, "GetInfo") else { return nil }
        var current = installed
        if current == nil { current = try await optional(Self.userInterface, "X_AVM-DE_GetInfo")?["NewX_AVM-DE_CurrentFwVersion"] }
        let available = values["NewUpgradeAvailable"] == "1" || values["NewX_AVM-DE_UpdateState"] == "UpdateAvailable"
        var page = URLComponents(); page.scheme = "http"; page.host = base.host
        let firmware = RouterFirmware(product: "FRITZ!OS", installed: RouterFirmware.fritzVersion(current),
                                      available: available ? RouterFirmware.fritzVersion(values["NewX_AVM-DE_Version"]) : nil,
                                      updateAvailable: available, url: page.url?.absoluteString)
        update = (Date(), firmware)
        return firmware
    }
    private var update: (date: Date, firmware: RouterFirmware)?
    public static let userInterface = "urn:dslforum-org:service:UserInterface:1"
    /// The user lacked a right during this poll.
    private var limited = false

    /// An action this user may not be allowed, or this box may not have: nil then.
    private func optional(_ type: String, _ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String]? {
        do { return try await call(type, action, arguments) }
        catch RouterAPIError.notAllowed { limited = true; return nil }
        catch RouterAPIError.unexpected { return nil }
    }

    /// X_AVM-DE_GetHostListPath, then that list: every device the box knows, online or not.
    func hostList() async throws -> [RouterClient] {
        guard let path = try await call(Self.hosts, "X_AVM-DE_GetHostListPath")["NewX_AVM-DE_HostListPath"], path.hasPrefix("/"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL, url.host == base.host else { throw RouterAPIError.unexpected("no host list") }
        let (data, response) = try await send(method: "GET", url: url, body: nil, headers: [:], authenticate: true)
        guard response.statusCode == 200 else { throw RouterAPIError.unexpected("host list \(response.statusCode)") }
        return TR064.hosts(data)
    }

    /// The same list one entry at a time, which needs no rights. One request per device, so it's read every five minutes at most.
    func genericHosts() async throws -> [RouterClient] {
        if let cached = generic, Date().timeIntervalSince(cached.date) < 300 { return cached.clients }
        let clients = try await readGenericHosts()
        generic = (Date(), clients)
        return clients
    }
    private var generic: (date: Date, clients: [RouterClient])?

    func readGenericHosts() async throws -> [RouterClient] {
        guard let count = try await call(Self.hosts, "GetHostNumberOfEntries")["NewHostNumberOfEntries"].flatMap({ Int($0) }) else { return [] }
        var clients: [RouterClient] = []
        for index in 0..<min(count, Self.maxHosts) {
            let entry = try await call(Self.hosts, "GetGenericHostEntry", [("NewIndex", String(index))])
            guard let mac = entry["NewMACAddress"].flatMap(MACAddress.normalized) else { continue }
            clients.append(RouterClient(mac: mac, address: entry["NewIPAddress"].flatMap { $0.isEmpty ? nil : $0 }, name: entry["NewHostName"], active: entry["NewActive"] == "1"))
        }
        return clients
    }

    /// One SOAP action; its out arguments by name.
    public func call(_ type: String, _ action: String, _ arguments: [(String, String)] = [], authenticate: Bool = true) async throws -> [String: String] {
        // Read-only by construction: only Get actions ever go out, never an update, reboot or setting.
        guard action.hasPrefix("Get") || action.hasPrefix("X_AVM-DE_Get") else { throw RouterAPIError.unexpected("\(action) isn't a read") }
        let control = try await controlURL(type)
        guard let url = URL(string: control, relativeTo: base)?.absoluteURL, url.host == base.host else { throw RouterAPIError.unexpected("control URL") }
        let args = arguments.map { "<\($0.0)>\(TR064.escape($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(type)\">\(args)</u:\(action)></s:Body></s:Envelope>"
        let (data, response) = try await send(method: "POST", url: url, body: Data(body.utf8),
                                              headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPACTION": "\"\(type)#\(action)\""], authenticate: authenticate)
        let parsed = TR064.parse(data)
        if let fault = parsed.fault {
            if fault == 606 { throw RouterAPIError.notAllowed(TR064.what(action)) }
            throw RouterAPIError.unexpected("\(action) error \(fault)")
        }
        guard response.statusCode == 200 else { throw RouterAPIError.unexpected("\(action) HTTP \(response.statusCode)") }
        return parsed.values
    }

    private func controlURL(_ type: String) async throws -> String {
        if controls == nil {
            let url = base.appendingPathComponent("tr64desc.xml")
            if let (data, response) = try? await send(method: "GET", url: url, body: nil, headers: [:], authenticate: false), response.statusCode == 200 {
                controls = TR064.services(data)
            } else { controls = [:] }
        }
        guard let control = controls?[type] ?? Self.defaultControls[type] else { throw RouterAPIError.unexpected("no \(type)") }
        return control
    }

    /// The request with digest authentication: sent once without it (or with the last nonce), and once more after a 401's challenge.
    private func send(method: String, url: URL, body: Data?, headers: [String: String], authenticate: Bool) async throws -> (Data, HTTPURLResponse) {
        let uri = url.path + (url.query.map { "?" + $0 } ?? "")
        for attempt in 0..<2 {
            var headers = headers
            if authenticate, var current = challenge {
                headers["Authorization"] = current.authorization(user: user, password: password, method: method, uri: uri)
                challenge = current
            }
            let (data, response) = try await transport.send(RouterHTTP.request(url, method: method, headers: headers, body: body))
            try RouterHTTP.check(data)
            switch response.statusCode {
            case 401:
                guard authenticate, attempt == 0, let header = response.value(forHTTPHeaderField: "WWW-Authenticate"), let fresh = DigestChallenge(header: header) else {
                    throw RouterAPIError.unauthorized
                }
                challenge = fresh
                continue
            case 503: throw RouterAPIError.busy
            default: return (data, response)
            }
        }
        throw RouterAPIError.unauthorized
    }
}

/// TR-064's XML: SOAP answers, the service list and the host list.
public enum TR064 {
    /// An action's out arguments, or the UPnP error code of a fault.
    public static func parse(_ data: Data) -> (values: [String: String], fault: Int?) {
        final class Reader: NSObject, XMLParserDelegate {
            var values: [String: String] = [:], text = "", leaf = true
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { text = ""; leaf = true }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if leaf { values[String(name.split(separator: ":").last ?? Substring(name))] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                leaf = false; text = ""
            }
        }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.delegate = reader; parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return (reader.values, reader.values["errorCode"].flatMap { Int($0) })
    }

    /// serviceType → controlURL from tr64desc.xml.
    public static func services(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [String: String] = [:]
        for block in text.components(separatedBy: "<service>").dropFirst() {
            guard let type = tag("serviceType", in: block), let control = tag("controlURL", in: block) else { continue }
            result[type] = control
        }
        return result
    }

    /// The host list's items. Read tag by tag rather than as strict XML: FRITZ!'s own documented example closes
    /// one tag with a different name, and a list that fails to parse would show no devices at all.
    public static func hosts(_ data: Data) -> [RouterClient] {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "<Item>").dropFirst().compactMap { item in
            guard let mac = tag("MACAddress", in: item).flatMap(MACAddress.normalized) else { return nil }
            let address = tag("IPAddress", in: item).flatMap { $0.isEmpty ? nil : $0 }
            let name = tag("X_AVM-DE_FriendlyName", in: item).flatMap { $0.isEmpty ? nil : $0 } ?? tag("HostName", in: item)
            return RouterClient(mac: mac, address: address, name: name, active: tag("Active", in: item) == "1")
        }
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>") else { return nil }
        let rest = text[open.upperBound...]
        guard let close = rest.range(of: "</") else { return nil }
        return unescape(String(rest[..<close.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The online monitor's newest values, bytes a second. Each is a comma-separated list, newest first.
    static func monitorRates(_ values: [String: String]) -> (down: Double?, up: Double?) {
        (first(values["Newds_current_bps"]), first(values["Newus_current_bps"]))
    }
    /// GetCommonLinkProperties' utilization lists, which any right may read.
    static func utilization(_ values: [String: String]) -> (down: Double?, up: Double?) {
        (first(values["NewX_AVM-DE_DownstreamCurrentUtilization"]), first(values["NewX_AVM-DE_UpstreamCurrentUtilization"]))
    }
    static func first(_ list: String?) -> Double? {
        list?.split(separator: ",").first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func what(_ action: String) -> String {
        switch action {
        case "X_AVM-DE_GetHostListPath": String(localized: "the device list", comment: "What a FRITZ!Box user may not read")
        case "GetInfo": String(localized: "the box’s uptime", comment: "What a FRITZ!Box user may not read")
        default: String(localized: "the line’s traffic", comment: "What a FRITZ!Box user may not read")
        }
    }
}

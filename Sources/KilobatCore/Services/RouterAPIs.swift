import Foundation

/// A UniFi OS console (Cloud Gateway, Dream Machine, Cloud Key) through UniFi Network's local APIs.
///
/// The official Integrations API (UniFi Network 9.3+, an API key from Settings › Control Plane › Integrations, in
/// the X-API-KEY header, under /proxy/network/integration/v1) lists sites and clients: name, MAC, IP, connected since,
/// uplink. It has no traffic. Each client's bytes and rates come from the controller's older API, which Ubiquiti
/// doesn't document: /proxy/network/api/s/<site>/stat/sta, read with the same key on recent versions, or after a
/// sign-in with a local account (/api/auth/login) on consoles without Integrations. tx is what the access point or
/// switch sent the client, so it is the client's download.
public actor UniFiConsole: RouterReader {
    public enum Auth: Sendable { case apiKey(String), account(user: String, password: String) }
    public struct Site: Sendable, Equatable { public var id: String; public var name: String; public var reference: String }

    let base: URL
    let auth: Auth
    var site: String?
    var siteName: String?
    let transport: RouterTransport
    private var cookie: String?
    private var csrf: String?

    public init(base: URL, auth: Auth, site: String? = nil, siteName: String? = nil, transport: RouterTransport) {
        self.base = base; self.auth = auth; self.site = site; self.siteName = siteName; self.transport = transport
    }

    public func sites() async throws -> [Site] {
        guard case .apiKey = auth else { return [Site(id: "", name: "Default", reference: siteName ?? "default")] }
        let value = try await get("/proxy/network/integration/v1/sites")
        let rows = ((value as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return Site(id: id, name: row["name"] as? String ?? "Default", reference: row["internalReference"] as? String ?? "default")
        }
    }

    /// The site picked when connecting: the first, which is the only one on a home console.
    public func chosenSite() async throws -> Site? {
        if case .apiKey = auth, site == nil, let first = try await sites().first { site = first.id; siteName = first.reference; return first }
        return site.map { Site(id: $0, name: siteName ?? "default", reference: siteName ?? "default") } ?? (siteName.map { Site(id: "", name: $0, reference: $0) })
    }

    public func poll() async throws -> RouterPoll {
        _ = try await chosenSite()
        var missing: [String] = []
        var clients: [String: RouterClient] = [:]
        if case .apiKey = auth, let site {
            for client in try await officialClients(site: site) { clients[client.mac] = client }
        }
        let reference = siteName ?? "default"
        var counted = false
        do {
            let value = try await get("/proxy/network/api/s/\(reference)/stat/sta")
            for row in Self.rows(value) {
                guard var client = Self.station(row) else { continue }
                if let known = clients[client.mac] { client.name = known.name ?? client.name; client.address = client.address ?? known.address }
                clients[client.mac] = client; counted = counted || client.counted
            }
        } catch RouterAPIError.unexpected { missing.append("legacyAPI") }
        catch RouterAPIError.unauthorized where clients.isEmpty == false { missing.append("legacyAPI") }
        var uptime: TimeInterval?, model: String?, firmware: String?, wan: RouterWAN?, update: RouterFirmware?
        if let value = try? await get("/proxy/network/api/s/\(reference)/stat/device") {
            for row in Self.rows(value) where ["udm", "ugw", "uxg", "ucg"].contains((row["type"] as? String) ?? "") {
                uptime = RouterHTTP.number(row["uptime"]); model = row["model"] as? String; firmware = row["version"] as? String
                // The controller's own flag for the gateway; the update itself stays in UniFi Network.
                let upgradable = row["upgradable"] as? Bool ?? false
                update = RouterFirmware(product: String(localized: "UniFi firmware", comment: "Router firmware name"), installed: firmware,
                                        available: upgradable ? (row["upgrade_to_firmware"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil,
                                        updateAvailable: upgradable, url: base.absoluteString)
                if let stats = row["uplink"] as? [String: Any] {
                    wan = RouterWAN(down: RouterHTTP.bytes(stats["rx_bytes"]), up: RouterHTTP.bytes(stats["tx_bytes"]),
                                    downRate: RouterHTTP.number(stats["rx_bytes-r"]), upRate: RouterHTTP.number(stats["tx_bytes-r"]))
                }
                break
            }
        }
        if wan == nil, let value = try? await get("/proxy/network/api/s/\(reference)/stat/health"),
           let line = Self.rows(value).first(where: { $0["subsystem"] as? String == "wan" }) {
            wan = RouterWAN(downRate: RouterHTTP.number(line["rx_bytes-r"]), upRate: RouterHTTP.number(line["tx_bytes-r"]))
        }
        var poll = RouterPoll(clients: Array(clients.values).sorted { $0.mac < $1.mac }, wan: wan, uptime: uptime, model: model, firmware: firmware,
                              perDevice: counted, missing: missing)
        poll.update = update
        return poll
    }

    /// The official client list, 200 at a time, at most 1,000.
    func officialClients(site: String) async throws -> [RouterClient] {
        var clients: [RouterClient] = [], offset = 0
        while offset < 1000 {
            let value = try await get("/proxy/network/integration/v1/sites/\(site)/clients?offset=\(offset)&limit=200")
            guard let page = value as? [String: Any], let rows = page["data"] as? [[String: Any]] else { break }
            for row in rows {
                guard let mac = (row["macAddress"] as? String).flatMap(MACAddress.normalized) else { continue }
                clients.append(RouterClient(mac: mac, address: row["ipAddress"] as? String, name: row["name"] as? String, active: true))
            }
            let total = (page["totalCount"] as? Int) ?? 0
            offset += rows.count
            if rows.isEmpty || offset >= total { break }
        }
        return clients
    }

    static func rows(_ value: Any) -> [[String: Any]] { ((value as? [String: Any])?["data"] as? [[String: Any]]) ?? [] }

    /// One stat/sta row: wireless clients carry tx_bytes and rx_bytes, wired ones the same with a wired- prefix.
    public static func station(_ row: [String: Any]) -> RouterClient? {
        guard let mac = (row["mac"] as? String).flatMap(MACAddress.normalized) else { return nil }
        let wired = row["is_wired"] as? Bool ?? false
        func field(_ name: String) -> Any? { wired ? row["wired-" + name] ?? row[name] : row[name] }
        let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row["hostname"] as? String
        return RouterClient(mac: mac, address: row["ip"] as? String, name: name, active: true,
                            down: RouterHTTP.bytes(field("tx_bytes")), up: RouterHTTP.bytes(field("rx_bytes")),
                            downRate: RouterHTTP.number(field("tx_bytes-r")), upRate: RouterHTTP.number(field("rx_bytes-r")))
    }

    private func get(_ path: String, retried: Bool = false) async throws -> Any {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw RouterAPIError.unexpected(path) }
        var headers = ["Accept": "application/json"]
        switch auth {
        case .apiKey(let key): headers["X-API-KEY"] = key
        case .account:
            if cookie == nil { try await signIn() }
            headers["Cookie"] = cookie; headers["X-CSRF-Token"] = csrf
        }
        let (data, response) = try await transport.send(RouterHTTP.request(url, headers: headers))
        switch response.statusCode {
        case 200: return try RouterHTTP.json(data)
        case 401, 403:
            if case .account = auth, !retried { cookie = nil; return try await get(path, retried: true) }
            // The official API turning the key down is a bad key; the older one may simply not take keys.
            if path.contains("/integration/") { throw RouterAPIError.unauthorized }
            throw RouterAPIError.unexpected("\(response.statusCode)")
        case 429: throw RouterAPIError.busy
        default: throw RouterAPIError.unexpected("HTTP \(response.statusCode)")
        }
    }

    /// A local account's sign-in on UniFi OS: a TOKEN cookie and a CSRF token.
    private func signIn() async throws {
        guard case .account(let user, let password) = auth, let url = URL(string: "/api/auth/login", relativeTo: base)?.absoluteURL else { return }
        let body = try JSONSerialization.data(withJSONObject: ["username": user, "password": password, "remember": false])
        let (_, response) = try await transport.send(RouterHTTP.request(url, method: "POST", headers: ["Content-Type": "application/json"], body: body))
        if response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 499 { throw RouterAPIError.unauthorized }
        if response.statusCode == 429 { throw RouterAPIError.busy }
        guard response.statusCode == 200, let set = response.value(forHTTPHeaderField: "Set-Cookie"),
              let token = set.split(separator: ";").first.map(String.init), token.hasPrefix("TOKEN=") else { throw RouterAPIError.unexpected("sign-in") }
        cookie = token
        csrf = response.value(forHTTPHeaderField: "X-Updated-CSRF-Token") ?? response.value(forHTTPHeaderField: "X-CSRF-Token")
    }
}

/// MikroTik RouterOS 7's REST API: HTTP Basic over www-ssl (or www from 7.9), JSON arrays whose values are all
/// strings. Leases and interfaces always; per-device bytes from Kid Control's device list (populated once a
/// profile exists) or, failing that, simple queues whose target is one address.
public struct RouterOSREST: RouterReader {
    let base: URL
    let user: String
    let password: String
    let transport: RouterTransport
    public init(base: URL, user: String, password: String, transport: RouterTransport) {
        self.base = base; self.user = user; self.password = password; self.transport = transport
    }

    func get(_ path: String) async throws -> Any {
        guard let url = URL(string: "/rest" + path, relativeTo: base)?.absoluteURL else { throw RouterAPIError.unexpected(path) }
        let (data, response) = try await transport.send(RouterHTTP.request(url, headers: ["Authorization": RouterHTTP.basic(user, password), "Accept": "application/json"]))
        switch response.statusCode {
        case 200: return try RouterHTTP.json(data)
        case 401: throw RouterAPIError.unauthorized
        case 403: throw RouterAPIError.notAllowed(path)
        default: throw RouterAPIError.unexpected("\(path) HTTP \(response.statusCode)")
        }
    }
    func list(_ path: String) async throws -> [[String: Any]] { (try await get(path) as? [[String: Any]]) ?? [] }

    public func poll() async throws -> RouterPoll {
        let resource = try await get("/system/resource") as? [String: Any]
        let leases = try await list("/ip/dhcp-server/lease")
        var clients: [String: RouterClient] = [:]
        for lease in leases {
            guard let mac = ((lease["active-mac-address"] ?? lease["mac-address"]) as? String).flatMap(MACAddress.normalized) else { continue }
            let address = (lease["active-address"] ?? lease["address"]) as? String
            let name = (lease["comment"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lease["host-name"] as? String
            clients[mac] = RouterClient(mac: mac, address: address, name: name, active: (lease["status"] as? String) == "bound")
        }
        var missing: [String] = [], perDevice = false
        if let kids = try? await list("/ip/kid-control/device"), !kids.isEmpty {
            for row in kids {
                guard let mac = (row["mac-address"] as? String).flatMap(MACAddress.normalized),
                      let down = Self.bytes(row["bytes-down"]), let up = Self.bytes(row["bytes-up"]) else { continue }
                var client = clients[mac] ?? RouterClient(mac: mac, address: row["ip-address"] as? String, name: row["name"] as? String)
                client.down = down; client.up = up; client.active = true
                clients[mac] = client; perDevice = true
            }
        } else { missing.append("kidControl") }
        if !perDevice, let queues = try? await list("/queue/simple") {
            let byAddress = Dictionary(clients.values.compactMap { client in client.address.map { ($0, client.mac) } }, uniquingKeysWith: { first, _ in first })
            for queue in queues where (queue["disabled"] as? String) != "true" {
                guard let targets = (queue["target"] as? String)?.split(separator: ",", omittingEmptySubsequences: false), targets.count == 1,
                      let target = targets.first.map({ $0.trimmingCharacters(in: .whitespaces) }), target.hasSuffix("/32"),
                      let mac = byAddress[String(target.dropLast(3))], let bytes = (queue["bytes"] as? String)?.split(separator: "/"), bytes.count == 2,
                      let up = UInt64(bytes[0]), let down = UInt64(bytes[1]) else { continue }
                clients[mac]?.up = up; clients[mac]?.down = down; perDevice = true
            }
            if perDevice { missing.append("queues") }
        }
        // The line: interfaces in the WAN list (the default configuration's), received is download.
        var wan: RouterWAN?
        if let members = try? await list("/interface/list/member"), let interfaces = try? await list("/interface") {
            let names = Set(members.filter { ($0["list"] as? String)?.uppercased() == "WAN" }.compactMap { $0["interface"] as? String })
            let lines = interfaces.filter { names.contains(($0["name"] as? String) ?? "") }
            if !lines.isEmpty {
                wan = RouterWAN(down: lines.compactMap { RouterHTTP.bytes($0["rx-byte"]) }.reduce(0, +), up: lines.compactMap { RouterHTTP.bytes($0["tx-byte"]) }.reduce(0, +))
            }
        }
        var poll = RouterPoll(clients: clients.values.sorted { $0.mac < $1.mac }, wan: wan, uptime: (resource?["uptime"] as? String).flatMap(Self.uptime),
                              model: resource?["board-name"] as? String, firmware: resource?["version"] as? String, perDevice: perDevice, missing: missing)
        // What RouterOS found the last time someone (or a script) ran Check For Updates; Kilobat never runs the check or an install.
        if let package = try? await get("/system/package/update") as? [String: Any] { poll.update = Self.update(package, base: base) }
        return poll
    }

    /// /system/package/update: installed-version against latest-version, which RouterOS fills in after a check.
    static func update(_ package: [String: Any], base: URL) -> RouterFirmware? {
        guard let installed = (package["installed-version"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        let latest = (package["latest-version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let newer = latest.map { RouterFirmware.isNewer($0, than: installed) } ?? false
        return RouterFirmware(product: "RouterOS", installed: installed, available: newer ? latest : nil, updateAvailable: newer, url: base.absoluteString)
    }

    /// RouterOS durations: "1w2d3h4m5s", or with a clock at the end, "2d03:04:05".
    public static func uptime(_ text: String) -> TimeInterval? {
        let units: [Character: Double] = ["w": 604_800, "d": 86_400, "h": 3600, "m": 60, "s": 1]
        var head = Substring(text.trimmingCharacters(in: .whitespaces)), total = 0.0
        guard !head.isEmpty else { return nil }
        if head.contains(":") {
            let split = head.lastIndex(where: \.isLetter).map { head.index(after: $0) } ?? head.startIndex
            let parts = head[split...].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            total = parts[0] * 3600 + parts[1] * 60 + parts[2]
            head = head[..<split]
        }
        var number = ""
        for character in head {
            if character.isNumber || character == "." { number.append(character) }
            else if let unit = units[character], let value = Double(number) { total += value * unit; number = "" }
            else { return nil }
        }
        return number.isEmpty ? total : nil
    }

    /// Byte counts as a plain number, or as RouterOS prints them ("3438.1KiB").
    static func bytes(_ value: Any?) -> UInt64? {
        if let plain = RouterHTTP.bytes(value) { return plain }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("B", 1)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)) else { return nil }
            let scaled = number * factor
            guard scaled.isFinite, scaled >= 0, scaled < 1.8e19 else { return nil }
            return UInt64(scaled)
        }
        return nil
    }
}

/// OpenWrt through rpcd's ubus over HTTP (uhttpd-mod-ubus at /ubus, as LuCI uses it): JSON-RPC with a session from
/// session.login. Host names from luci-rpc getHostHints, uptime from system info, the WAN interface's counters from
/// netifd; per-device bytes from nlbwmon when it is installed, through the same action LuCI's bandwidth page runs.
public actor OpenWrtUbus: RouterReader {
    static let anonymous = "00000000000000000000000000000000"
    let base: URL
    let user: String
    let password: String
    let transport: RouterTransport
    private var session: String?
    private var id = 0

    public init(base: URL, user: String, password: String, transport: RouterTransport) {
        self.base = base; self.user = user; self.password = password; self.transport = transport
    }

    public func poll() async throws -> RouterPoll {
        let hints = try await call("luci-rpc", "getHostHints") ?? [:]
        var clients: [String: RouterClient] = [:]
        for (key, value) in hints {
            guard let mac = MACAddress.normalized(key), let hint = value as? [String: Any] else { continue }
            let address = (hint["ipaddrs"] as? [String])?.first ?? (hint["ipv4"] as? String)
            clients[mac] = RouterClient(mac: mac, address: address, name: hint["name"] as? String, active: address != nil)
        }
        let info = try? await call("system", "info")
        let board = try? await call("system", "board")
        var wan: RouterWAN?
        if let status = try? await call("network.interface.wan", "status"), let device = (status["l3_device"] ?? status["device"]) as? String,
           let stats = (try? await call("network.device", "status", ["name": device]))?["statistics"] as? [String: Any] {
            wan = RouterWAN(down: RouterHTTP.bytes(stats["rx_bytes"]), up: RouterHTTP.bytes(stats["tx_bytes"]))
        }
        var missing: [String] = [], perDevice = false
        if let output = try? await call("file", "exec", ["command": "/usr/libexec/nlbwmon-action", "params": ["download", "-g", "mac"]]),
           (output["code"] as? Int) == 0, let stdout = output["stdout"] as? String, let table = Self.nlbw(Data(stdout.utf8)) {
            for (mac, bytes) in table {
                var client = clients[mac] ?? RouterClient(mac: mac, active: false)
                client.down = bytes.down; client.up = bytes.up
                clients[mac] = client
            }
            perDevice = true
        } else { missing.append("nlbwmon") }
        let release = board?["release"] as? [String: Any]
        var poll = RouterPoll(clients: clients.values.sorted { $0.mac < $1.mac }, wan: wan, uptime: RouterHTTP.number(info?["uptime"]),
                              model: board?["model"] as? String, firmware: release?["description"] as? String, perDevice: perDevice, missing: missing)
        if let distribution = release?["distribution"] as? String, let version = release?["version"] as? String { poll.release = (distribution, version) }
        return poll
    }

    /// nlbwmon's JSON (`nlbw -c json -g mac`): columns, then rows. rx is what the device received, its download.
    public static func nlbw(_ data: Data) -> [String: (down: UInt64, up: UInt64)]? {
        guard let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let columns = table["columns"] as? [String],
              let rows = table["data"] as? [[Any]], let mac = columns.firstIndex(of: "mac"), let rx = columns.firstIndex(of: "rx_bytes"),
              let tx = columns.firstIndex(of: "tx_bytes") else { return nil }
        var result: [String: (down: UInt64, up: UInt64)] = [:]
        for row in rows where row.count > max(mac, rx, tx) {
            guard let address = (row[mac] as? String).flatMap(MACAddress.normalized), MACAddress.unicast(address),
                  let down = RouterHTTP.bytes(row[rx]), let up = RouterHTTP.bytes(row[tx]) else { continue }
            let previous = result[address] ?? (0, 0)
            result[address] = (previous.down + down, previous.up + up)
        }
        return result
    }

    /// One ubus call; nil for an empty answer. Signs in first, and again once when the session expired.
    func call(_ object: String, _ method: String, _ arguments: [String: Any] = [:], retried: Bool = false) async throws -> [String: Any]? {
        if session == nil { session = try await login() }
        let (status, value) = try await rpc([session ?? Self.anonymous, object, method, arguments])
        if status == 6 || status == -32002 {
            guard !retried else { throw RouterAPIError.notAllowed("\(object) \(method)") }
            session = nil
            return try await call(object, method, arguments, retried: true)
        }
        guard status == 0 else { throw RouterAPIError.unexpected("\(object) \(method): \(status)") }
        return value
    }

    func login() async throws -> String {
        let (status, value) = try await rpc([Self.anonymous, "session", "login", ["username": user, "password": password]])
        guard status == 0, let token = value?["ubus_rpc_session"] as? String else { throw RouterAPIError.unauthorized }
        return token
    }

    /// The ubus status (0 is OK; 6 permission denied) and the answer; a JSON-RPC error's code stands in for the status.
    private func rpc(_ params: [Any]) async throws -> (Int, [String: Any]?) {
        guard let url = URL(string: "/ubus", relativeTo: base)?.absoluteURL else { throw RouterAPIError.unexpected("ubus") }
        id += 1
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "call", "params": params])
        let (data, response) = try await transport.send(RouterHTTP.request(url, method: "POST", headers: ["Content-Type": "application/json"], body: body))
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw RouterAPIError.unexpected("no /ubus: install uhttpd-mod-ubus or LuCI") }
            throw RouterAPIError.unexpected("HTTP \(response.statusCode)")
        }
        guard let reply = try RouterHTTP.json(data) as? [String: Any] else { throw RouterAPIError.unexpected("ubus") }
        if let error = reply["error"] as? [String: Any] { return ((error["code"] as? Int) ?? -1, nil) }
        guard let result = reply["result"] as? [Any], let status = result.first as? Int else { throw RouterAPIError.unexpected("ubus result") }
        return (status, result.count > 1 ? result[1] as? [String: Any] : nil)
    }
}

import Foundation
import Network

/// Recorded router answers, shaped as each maker documents them, with documentation addresses (192.0.2.0/24 for
/// devices, RFC 7042's 00:00:5e:00:53:xx MACs) and made-up names. No real router was asked.
enum RouterFixtures {
    // MARK: FRITZ!Box TR-064 (FRITZ! "TR-064 First Steps", DeviceInfo, Hosts and WANCommonInterfaceConfig PDFs)

    static let tr64desc = """
    <?xml version="1.0"?><root xmlns="urn:dslforum-org:device-1-0"><device><deviceType>urn:dslforum-org:device:InternetGatewayDevice:1</deviceType>
    <manufacturer>AVM</manufacturer><modelName>FRITZ!Box 7590</modelName><serviceList>
    <service><serviceType>urn:dslforum-org:service:DeviceInfo:1</serviceType><serviceId>urn:DeviceInfo-com:serviceId:DeviceInfo1</serviceId><controlURL>/upnp/control/deviceinfo</controlURL><eventSubURL>/upnp/control/deviceinfo</eventSubURL><SCPDURL>/deviceinfoSCPD.xml</SCPDURL></service>
    </serviceList><deviceList><device><serviceList>
    <service><serviceType>urn:dslforum-org:service:Hosts:1</serviceType><serviceId>urn:LanDeviceHosts-com:serviceId:Hosts1</serviceId><controlURL>/upnp/control/hosts</controlURL><SCPDURL>/hostsSCPD.xml</SCPDURL></service>
    <service><serviceType>urn:dslforum-org:service:WANCommonInterfaceConfig:1</serviceType><serviceId>urn:WANCIfConfig-com:serviceId:WANCommonInterfaceConfig1</serviceId><controlURL>/upnp/control/wancommonifconfig1</controlURL><SCPDURL>/wancommonifconfigSCPD.xml</SCPDURL></service>
    </serviceList></device></deviceList></device></root>
    """

    static func soap(_ action: String, _ service: String, _ values: [(String, String)]) -> String {
        let body = values.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\n<u:\(action)Response xmlns:u=\"\(service)\">\n\(body)\n</u:\(action)Response>\n</s:Body> </s:Envelope>"
    }

    static let securityPort = soap("GetSecurityPort", "urn:dslforum-org:service:DeviceInfo:1", [("NewSecurityPort", "49443")])
    static let getInfo = soap("GetInfo", "urn:dslforum-org:service:DeviceInfo:1", [
        ("NewManufacturerName", "AVM"), ("NewManufacturerOUI", "00040E"), ("NewModelName", "FRITZ!Box 7590"), ("NewDescription", "FRITZ!Box 7590 154.08.00"),
        ("NewProductClass", "AVMFB7590"), ("NewSerialNumber", "000000000000"), ("NewSoftwareVersion", "154.08.00"), ("NewHardwareVersion", "FRITZ!Box 7590"),
        ("NewSpecVersion", "1.0"), ("NewProvisioningCode", ""), ("NewUpTime", "86400"), ("NewDeviceLog", "")])
    static let hostListPath = soap("X_AVM-DE_GetHostListPath", "urn:dslforum-org:service:Hosts:1", [("NewX_AVM-DE_HostListPath", "/devicehostlist.lua?sid=0123456789abcdef")])
    static let totalReceived = soap("GetTotalBytesReceived", "urn:dslforum-org:service:WANCommonInterfaceConfig:1", [("NewTotalBytesReceived", "4294967000")])
    static let totalSent = soap("GetTotalBytesSent", "urn:dslforum-org:service:WANCommonInterfaceConfig:1", [("NewTotalBytesSent", "123456789")])
    static let onlineMonitor = soap("X_AVM-DE_GetOnlineMonitor", "urn:dslforum-org:service:WANCommonInterfaceConfig:1", [
        ("NewTotalNumberSyncGroups", "1"), ("NewSyncGroupName", "sync_dsl"), ("NewSyncGroupMode", "VDSL"), ("Newmax_ds", "13900000"), ("Newmax_us", "5000000"),
        ("Newds_current_bps", "3200000,3100000,2900000,40000"), ("Newmc_current_bps", "0,0,0,0"), ("Newus_current_bps", "210000,190000,180000,9000"),
        ("Newprio_realtime_bps", "1000,0,0,0"), ("Newprio_high_bps", "0,0,0,0"), ("Newprio_default_bps", "209000,190000,180000,9000"), ("Newprio_low_bps", "0,0,0,0")])
    static let linkProperties = soap("GetCommonLinkProperties", "urn:dslforum-org:service:WANCommonInterfaceConfig:1", [
        ("NewWANAccessType", "DSL"), ("NewLayer1UpstreamMaxBitRate", "40000000"), ("NewLayer1DownstreamMaxBitRate", "110000000"), ("NewPhysicalLinkStatus", "Up"),
        ("NewX_AVM-DE_DownstreamCurrentUtilization", "1500000,1400000"), ("NewX_AVM-DE_UpstreamCurrentUtilization", "60000,50000"),
        ("NewX_AVM-DE_DownstreamCurrentMaxSpeed", "1500000"), ("NewX_AVM-DE_UpstreamCurrentMaxSpeed", "60000")])
    /// UserInterface:GetInfo (FRITZ! "TR-064 Support – UserInterface"): the box found newer FRITZ!OS itself.
    static let userInterface = soap("GetInfo", "urn:dslforum-org:service:UserInterface:1", [
        ("NewUpgradeAvailable", "1"), ("NewPasswordRequired", "0"), ("NewPasswordUserSelectable", "1"), ("NewWarrantyDate", "0001-01-01T00:00:00"),
        ("NewX_AVM-DE_Version", "154.08.10"), ("NewX_AVM-DE_DownloadURL", "http://download.avm.de/fritzbox/fritzbox-7590/deutschland/fritz.os/FRITZ.Box_7590-08.10.image"),
        ("NewX_AVM-DE_InfoURL", "http://download.avm.de/fritzbox/fritzbox-7590/deutschland/fritz.os/info_de.txt"), ("NewX_AVM-DE_UpdateState", "UpdateAvailable"),
        ("NewX_AVM-DE_BuildType", "Release"), ("NewX_AVM-DE_SetupAssistantStatus", "1")])
    static let hostCount = soap("GetHostNumberOfEntries", "urn:dslforum-org:service:Hosts:1", [("NewHostNumberOfEntries", "2")])
    static func genericHost(_ index: Int) -> String {
        let rows = [("192.0.2.31", "00:00:5E:00:53:31", "Sams-MacBook-Air", "1"), ("192.0.2.44", "00:00:5E:00:53:44", "Ritas-iPad", "0")]
        let row = rows[min(index, rows.count - 1)]
        return soap("GetGenericHostEntry", "urn:dslforum-org:service:Hosts:1", [("NewIPAddress", row.0), ("NewAddressSource", "DHCP"), ("NewLeaseTimeRemaining", "0"),
                                                                                  ("NewMACAddress", row.1), ("NewInterfaceType", "802.11"), ("NewActive", row.3), ("NewHostName", row.2)])
    }
    /// A user without the right, as TR-064 answers: SOAP fault 606, Action Not Authorized.
    static let notAuthorized = """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>606</errorCode><errorDescription>Action Not Authorized</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
    """
    /// The host list as FRITZ!'s Hosts document shows it, including its example's mismatched closing tag.
    static let hostList = """
    <List>
    <!-- devicehosts :3 -->
    <Item><Index>1</Index><IPAddress>192.0.2.31</IPAddress><MACAddress>00:00:5E:00:53:31</MACAddress><Active>1</Active><HostName>Sams-MacBook-Air</HostName><InterfaceType>802.11</InterfaceType><X_AVM-DE_Port>0</X_AVM-DE_Port><X_AVM-DE_Speed>866</X_AVM-DE_Speed><X_AVM-DE_URLParameters>token=0000</X_AVM-DE_URLParameter><X_AVM-DE_Guest>0</X_AVM-DE_Guest><X_AVM-DE_FriendlyName>Sams-MacBook-Air</X_AVM-DE_FriendlyName></Item>
    <Item><Index>2</Index><IPAddress>192.0.2.44</IPAddress><MACAddress>00:00:5E:00:53:44</MACAddress><Active>1</Active><HostName>Ritas-iPad</HostName><InterfaceType>802.11</InterfaceType><X_AVM-DE_Speed>400</X_AVM-DE_Speed><X_AVM-DE_FriendlyName/></Item>
    <Item><Index>3</Index><IPAddress>192.0.2.20</IPAddress><MACAddress>00:00:5E:00:53:20</MACAddress><Active>0</Active><HostName>Bedroom &amp; TV</HostName><InterfaceType>Ethernet</InterfaceType><X_AVM-DE_Speed>0</X_AVM-DE_Speed></Item>
    </List>
    """

    // MARK: UniFi Network (Integrations API v1, and the controller's stat/sta)

    static let unifiSites = #"{"offset":0,"limit":25,"count":1,"totalCount":1,"data":[{"id":"88f7af54-98f8-306a-a1c7-c9349722b1f6","internalReference":"default","name":"Default"}]}"#
    static let unifiClients = #"{"offset":0,"limit":200,"count":2,"totalCount":2,"data":[{"type":"WIRELESS","id":"497b6d0c-1d3b-3d5a-9c2f-6a54b4a9c2b1","name":"Rita’s iPad","connectedAt":"2026-11-01T08:12:00Z","ipAddress":"192.0.2.44","macAddress":"00:00:5e:00:53:44","uplinkDeviceId":"6f2b3a1e-0000-0000-0000-000000000001","access":{"type":"DEFAULT"}},{"type":"WIRED","id":"a3c1d2e4-1d3b-3d5a-9c2f-6a54b4a9c2b2","name":"Bedroom TV","connectedAt":"2026-11-01T07:00:00Z","ipAddress":"192.0.2.20","macAddress":"00:00:5e:00:53:20","uplinkDeviceId":"6f2b3a1e-0000-0000-0000-000000000002","access":{"type":"DEFAULT"}}]}"#
    static let unifiStations = #"{"meta":{"rc":"ok"},"data":[{"mac":"00:00:5e:00:53:44","ip":"192.0.2.44","hostname":"Ritas-iPad","is_wired":false,"tx_bytes":5368709120,"rx_bytes":104857600,"tx_bytes-r":3900000.5,"rx_bytes-r":41000.2,"uptime":14400},{"mac":"00:00:5e:00:53:20","ip":"192.0.2.20","name":"","hostname":"tv","is_wired":true,"wired-tx_bytes":2147483648,"wired-rx_bytes":52428800,"wired-tx_bytes-r":800000,"wired-rx_bytes-r":12000,"uptime":20000}]}"#
    static let unifiDevices = #"{"meta":{"rc":"ok"},"data":[{"type":"uap","model":"U7PG2","uptime":99},{"type":"udm","model":"UDR7","version":"4.3.9","upgradable":true,"upgrade_to_firmware":"4.4.6","uptime":259200,"uplink":{"rx_bytes":9000000000,"tx_bytes":800000000,"rx_bytes-r":4800000,"tx_bytes-r":70000}}]}"#
    static let unifiLoginRequired = #"{"meta":{"rc":"error","msg":"api.err.LoginRequired"},"data":[]}"#

    // MARK: MikroTik RouterOS 7 REST (every value a string)

    static let rosResource = #"{"architecture-name":"arm64","board-name":"hAP ax^3","cpu-load":"3","uptime":"1w2d3h4m5s","version":"7.16.1 (stable)"}"#
    static let rosLeases = #"[{".id":"*1","address":"192.0.2.44","mac-address":"00:00:5E:00:53:44","host-name":"Ritas-iPad","status":"bound","dynamic":"true"},{".id":"*2","address":"192.0.2.20","mac-address":"00:00:5E:00:53:20","host-name":"tv","comment":"Bedroom TV","status":"bound"},{".id":"*3","address":"192.0.2.61","mac-address":"00:00:5E:00:53:61","host-name":"plug","status":"waiting"}]"#
    static let rosKids = #"[{".id":"*A","mac-address":"00:00:5E:00:53:44","ip-address":"192.0.2.44","name":"","user":"everyone","bytes-down":"5368709120","bytes-up":"104857600","rate-down":"3.9Mbps","rate-up":"41.0kbps","idle-time":"0s"},{".id":"*B","mac-address":"00:00:5E:00:53:20","ip-address":"192.0.2.20","user":"everyone","bytes-down":"2048.0MiB","bytes-up":"50.0MiB"}]"#
    static let rosQueues = #"[{".id":"*1","name":"tv","target":"192.0.2.20/32","bytes":"52428800/2147483648","rate":"0/0","disabled":"false"},{".id":"*2","name":"lan","target":"192.0.2.0/24","bytes":"1/2","disabled":"false"}]"#
    static let rosPackageUpdate = #"{"channel":"stable","installed-version":"7.16.1","latest-version":"7.16.2","status":"New version is available"}"#
    static let rosListMembers = #"[{".id":"*1","list":"WAN","interface":"ether1"},{".id":"*2","list":"LAN","interface":"bridge"}]"#
    static let rosInterfaces = #"[{".id":"*1","name":"ether1","type":"ether","rx-byte":"90000000000","tx-byte":"8000000000","running":"true"},{".id":"*2","name":"bridge","type":"bridge","rx-byte":"1","tx-byte":"2"}]"#

    // MARK: OpenWrt rpcd/ubus JSON-RPC

    static func ubus(_ id: Any, _ status: Int, _ value: String? = nil) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":[\(status)\(value.map { "," + $0 } ?? "")]}"
    }
    static let owLogin = #"{"ubus_rpc_session":"c1ed6c7b025d0caca723a816fa61b668","timeout":300,"expires":299,"acls":{},"data":{"username":"root"}}"#
    static let owHints = #"{"00:00:5E:00:53:44":{"ipaddrs":["192.0.2.44"],"ip6addrs":[],"name":"Ritas-iPad"},"00:00:5E:00:53:20":{"ipaddrs":["192.0.2.20"],"name":"tv"},"00:00:5E:00:53:61":{"ip6addrs":["fe80::1"]}}"#
    static let owInfo = #"{"localtime":1793570000,"uptime":432000,"load":[0,0,0],"memory":{"total":512000000}}"#
    static let owBoard = #"{"kernel":"6.6.73","hostname":"OpenWrt","model":"GL.iNet GL-MT6000","release":{"distribution":"OpenWrt","version":"24.10.0","description":"OpenWrt 24.10.0"}}"#
    static let owWAN = #"{"up":true,"l3_device":"eth1","device":"eth1","proto":"dhcp"}"#
    static let owDevice = #"{"up":true,"statistics":{"rx_bytes":70000000000,"tx_bytes":6000000000,"rx_packets":1,"tx_packets":2}}"#
    /// downloads.openwrt.org/.versions.json, cut short.
    static let owVersions = #"{"stable_version":"25.12.6","oldstable_version":"24.10.8","upcoming_version":"","versions_list":["25.12.6","25.12.5","25.12.0-rc1","25.12.0","24.10.8","24.10.7","24.10.0","23.05.5"]}"#
    static let owNlbw = #"{"columns":["mac","conns","rx_bytes","rx_pkts","tx_bytes","tx_pkts"],"data":[["00:00:5e:00:53:44",12,5368709120,1,104857600,2],["00:00:5e:00:53:20",3,2147483648,1,52428800,2],["00:00:00:00:00:00",1,5,1,5,1]]}"#
}

/// A tiny HTTP/1.1 server on a free loopback port: one request per connection, answered by `handler`.
final class FakeRouter: @unchecked Sendable {
    struct Request: Sendable { let method: String; let path: String; let headers: [String: String]; let body: Data; var text: String { String(decoding: body, as: UTF8.self) } }
    struct Reply: Sendable {
        var status = 200; var headers: [String: String] = [:]; var body = ""
        init(_ status: Int = 200, _ body: String = "", headers: [String: String] = [:]) { self.status = status; self.body = body; self.headers = headers }
    }
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-router")
    private let handler: @Sendable (Request) -> Reply
    private let lock = NSLock()
    private var log: [Request] = []
    var requests: [Request] { lock.withLock { log } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(_ handler: @escaping @Sendable (Request) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in if case .ready = state { continuation.resume() } }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.log.append(request) }
                let reply = self.handler(request)
                var head = "HTTP/1.1 \(reply.status) Fake\r\nContent-Length: \(Data(reply.body.utf8).count)\r\nConnection: close\r\n"
                for (key, value) in reply.headers { head += "\(key): \(value)\r\n" }
                connection.send(content: Data((head + "\r\n" + reply.body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if done || error != nil { connection.cancel() }
            else { self.read(connection, buffer) }
        }
    }

    static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }
}

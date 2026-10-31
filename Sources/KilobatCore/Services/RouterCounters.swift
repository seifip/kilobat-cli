import Darwin
import Foundation

public struct RouterReading: Codable, Sendable {
    public let date: Date
    public let received: UInt64
    public let sent: UInt64
}
/// Optional read-only UPnP WAN counters. Never enables UPnP or changes port mappings.
public enum RouterCounters {
    public static func read(controlURL: String) async throws -> RouterReading {
        guard let url = URL(string: controlURL), ["http", "https"].contains(url.scheme), let host = url.host, url.user == nil, url.password == nil,
              let address = IPv4PrivateAddress(host) else { throw DiagnosticError(String(localized: "Enter your router's private IPv4 UPnP WANCommonInterfaceConfig control URL, with no credentials.")) }
        _ = address
        async let received = counter("GetTotalBytesReceived", field: "NewTotalBytesReceived", url: url)
        async let sent = counter("GetTotalBytesSent", field: "NewTotalBytesSent", url: url)
        return try await RouterReading(date: Date(), received: received, sent: sent)
    }
    /// The WAN counters' control URL of the router at `gateway`, found with UPnP's M-SEARCH: asked of the router
    /// directly, then on the multicast group. Nil when the router doesn't offer UPnP; nothing is changed either way.
    public static func discover(gateway: String) async -> String? {
        guard IPv4PrivateAddress(gateway) != nil else { return nil }
        for target in [gateway, "239.255.255.250"] {
            for location in await search(target) where URL(string: location)?.host == gateway {
                if let control = await controlURL(location) { return control }
            }
        }
        return nil
    }

    /// LOCATION headers from M-SEARCH replies within two seconds.
    static func search(_ target: String) async -> [String] {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(1900).bigEndian
            inet_pton(AF_INET, target, &address.sin_addr)
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
            _ = message.withCString { text in withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
            var locations: [String] = [], buffer = [UInt8](repeating: 0, count: 2048)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { continue }
                if let location = locationHeader(String(decoding: buffer.prefix(count), as: UTF8.self)), !locations.contains(location) { locations.append(location) }
            }
            return locations
        }.value
    }

    public static func locationHeader(_ reply: String) -> String? {
        reply.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("location:") }.map { String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
    }

    /// The WANCommonInterfaceConfig control URL in a device description, resolved against where it came from.
    static func controlURL(_ location: String) async -> String? {
        guard let url = URL(string: location), let host = url.host, IPv4PrivateAddress(host) != nil else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request), data.count <= 262_144 else { return nil }
        return controlURL(description: data, base: url)
    }

    public static func controlURL(description data: Data, base: URL) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for service in text.components(separatedBy: "<service>").dropFirst() where service.contains("WANCommonInterfaceConfig") {
            guard let start = service.range(of: "<controlURL>"), let end = service.range(of: "</controlURL>", range: start.upperBound..<service.endIndex) else { continue }
            let path = service[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: path, relativeTo: base)?.absoluteString
        }
        return nil
    }

    static func IPv4PrivateAddress(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard parts.count == 4, values.count == 4, values.allSatisfy({ (0...255).contains($0) }), values[0] == 10 || values[0] == 192 && values[1] == 168 || values[0] == 172 && (16...31).contains(values[1]) else { return nil }
        return values
    }
    private static func counter(_ action: String, field: String, url: URL) async throws -> UInt64 {
        let service = "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service)\"/></s:Body></s:Envelope>".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536 else { throw DiagnosticError(String(localized: "Router does not expose this counter at that control URL.")) }
        return try parse(data, field: field)
    }
    public static func parse(_ data: Data, field: String) throws -> UInt64 {
        final class Reader: NSObject, XMLParserDelegate {
            let field: String; var inside = false; var value = ""
            init(_ field: String) { self.field = field }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { inside = name.components(separatedBy: ":").last == field }
            func parser(_ parser: XMLParser, foundCharacters text: String) { if inside { value += text } }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { inside = false }
        }
        let reader = Reader(field), parser = XMLParser(data: data); parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let value = UInt64(reader.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw DiagnosticError(String(localized: "Router returned no valid byte counter.")) }
        return value
    }
}

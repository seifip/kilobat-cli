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
              let address = IPv4PrivateAddress(host) else { throw DiagnosticError("Enter your router's private IPv4 UPnP WANCommonInterfaceConfig control URL, with no credentials.") }
        _ = address
        async let received = counter("GetTotalBytesReceived", field: "NewTotalBytesReceived", url: url)
        async let sent = counter("GetTotalBytesSent", field: "NewTotalBytesSent", url: url)
        return try await RouterReading(date: Date(), received: received, sent: sent)
    }
    private static func IPv4PrivateAddress(_ host: String) -> [Int]? {
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
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536 else { throw DiagnosticError("Router does not expose this counter at that control URL.") }
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
        guard parser.parse(), let value = UInt64(reader.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw DiagnosticError("Router returned no valid byte counter.") }
        return value
    }
}

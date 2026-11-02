import Darwin
import Foundation

/// What a UPnP device's description says it is: its device type, maker and model. Kilobat leaves out its
/// friendly name and serial number.
public struct UPnPDescription: Codable, Sendable, Equatable {
    /// `urn:schemas-upnp-org:device:MediaRenderer:1`.
    public var deviceType: String?
    public var manufacturer: String?
    public var modelName: String?
    public init(deviceType: String? = nil, manufacturer: String? = nil, modelName: String? = nil) {
        self.deviceType = deviceType; self.manufacturer = manufacturer; self.modelName = modelName
    }
    /// `urn:schemas-upnp-org:device:MediaRenderer:1` as `MediaRenderer`.
    public var shortType: String? {
        guard let deviceType else { return nil }
        let parts = deviceType.split(separator: ":")
        guard parts.count >= 2 else { return deviceType.isEmpty ? nil : deviceType }
        return String(parts[parts.count - 2])
    }

    /// The root device's fields in a UPnP description document; nil when it isn't one.
    public static func parse(_ data: Data) -> UPnPDescription? {
        final class Reader: NSObject, XMLParserDelegate {
            var depth = 0, deviceDepth: Int?, field: String?, text = ""
            var found = UPnPDescription()
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                depth += 1
                let local = name.components(separatedBy: ":").last ?? name
                if local == "device", deviceDepth == nil { deviceDepth = depth }
                // Only the root device's own fields, not those of the devices nested in its deviceList.
                field = deviceDepth.map { depth == $0 + 1 } == true && ["deviceType", "manufacturer", "modelName"].contains(local) ? local : nil
                text = ""
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { if field != nil { text += string } }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let field, !value.isEmpty, value.count <= 120 {
                    switch field {
                    case "deviceType": if found.deviceType == nil { found.deviceType = value }
                    case "manufacturer": if found.manufacturer == nil { found.manufacturer = value }
                    default: if found.modelName == nil { found.modelName = value }
                    }
                }
                field = nil; depth -= 1
            }
        }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.found != UPnPDescription() else { return nil }
        return reader.found
    }
}

/// Asks the local network's UPnP devices who they are (SSDP's M-SEARCH for everything), the way a TV remote app
/// does. Read-only: it never asks a device to change anything, and fetches descriptions only from private addresses
/// on the local network.
public enum SSDPDiscovery {
    /// One reply: who sent it, where its description is, and what it answered for.
    public struct Reply: Sendable, Equatable {
        public let address: String
        public let location: String?
        public let target: String?
        public init(address: String, location: String?, target: String?) { self.address = address; self.location = location; self.target = target }
    }

    /// Replies to one multicast M-SEARCH within `seconds`, at most 200.
    public static func search(seconds: Double = 2) async -> [Reply] {
        await Task.detached(priority: .utility) {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(1900).bigEndian
            inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n"
            for _ in 0..<2 {
                _ = message.withCString { text in withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
            }
            var replies: [Reply] = [], buffer = [UInt8](repeating: 0, count: 2048)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, replies.count < 200 {
                var from = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
                guard count > 0 else { continue }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                let reply = parse(String(decoding: buffer.prefix(count), as: UTF8.self), from: String(cString: text))
                if !replies.contains(reply) { replies.append(reply) }
            }
            return replies
        }.value
    }

    /// An M-SEARCH reply's LOCATION and ST headers.
    public static func parse(_ reply: String, from address: String) -> Reply {
        var location: String?, target: String?
        for line in reply.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") { location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            if lower.hasPrefix("st:") { target = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        }
        return Reply(address: address, location: location, target: target)
    }

    /// The description at `location`, only when it is served by the device that replied, from a private address.
    public static func describe(_ location: String, address: String) async -> UPnPDescription? {
        guard let url = URL(string: location), ["http", "https"].contains(url.scheme), url.host == address, url.user == nil,
              RouterCounters.IPv4PrivateAddress(address) != nil else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 3
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: DescriptionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // A local device's redirect must not turn discovery into an external request.
        guard let (data, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 262_144 else { return nil }
        return UPnPDescription.parse(data)
    }

    private final class DescriptionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

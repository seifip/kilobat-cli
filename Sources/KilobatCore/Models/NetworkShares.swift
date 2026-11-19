import Foundation

/// A mounted network share, as the kernel's mount table lists it. Kilobat reads only the table and knocks on the
/// server's port; it never opens, lists or stats anything on the share, since a call on a dead mount can hang.
public struct NetworkShare: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case smb, afp, nfs, webdav
        public var title: String {
            switch self { case .smb: "SMB"; case .afp: "AFP"; case .nfs: "NFS"; case .webdav: "WebDAV" }
        }
    }
    /// How to reach the server: a host and port, or a Bonjour name the share was mounted by.
    public enum Endpoint: Codable, Sendable, Equatable {
        case host(String, port: Int)
        case bonjour(name: String, type: String, domain: String)
    }
    public var id: String { mountPoint }
    public let kind: Kind
    /// "nas.local", "Synology", "192.168.1.20"
    public let server: String
    /// "Public"; the export path for NFS.
    public let share: String
    public let mountPoint: String
    public let endpoint: Endpoint

    public init(kind: Kind, server: String, share: String, mountPoint: String, endpoint: Endpoint) {
        self.kind = kind; self.server = server; self.share = share; self.mountPoint = mountPoint; self.endpoint = endpoint
    }

    /// The volume's name in Finder: the mount point's last part.
    public var volume: String { (mountPoint as NSString).lastPathComponent }

    /// From one mount table entry: its file system type (`f_fstypename`), source (`f_mntfromname`) and mount point.
    /// Nil for anything that isn't a network share.
    public static func parse(type: String, from source: String, on mountPoint: String) -> NetworkShare? {
        let kind: Kind
        switch type {
        case "smbfs": kind = .smb
        case "afpfs": kind = .afp
        case "nfs": kind = .nfs
        case "webdav": kind = .webdav
        default: return nil
        }
        switch kind {
        case .smb, .afp:
            // "//user;DOMAIN@host:port/Share", "//GUEST:@Synology._smb._tcp.local/Public", "//host/Share"
            guard source.hasPrefix("//") else { return nil }
            let rest = source.dropFirst(2)
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = String(rest[..<slash])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            let share = slash < rest.endIndex ? String(rest[rest.index(after: slash)...]) : ""
            guard let (host, port) = hostAndPort(authority, default: kind == .smb ? 445 : 548) else { return nil }
            return make(kind: kind, host: host, port: port, share: decode(share), mountPoint: mountPoint)
        case .nfs:
            // "server:/export/path", "[fd00::5]:/export"
            let host: String, path: String
            if source.hasPrefix("["), let close = source.firstIndex(of: "]") {
                host = String(source[source.index(after: source.startIndex)..<close])
                path = String(source[source.index(after: close)...].drop { $0 == ":" })
            } else if let colon = source.firstIndex(of: ":") {
                host = String(source[..<colon]); path = String(source[source.index(after: colon)...])
            } else { return nil }
            guard !host.isEmpty else { return nil }
            return NetworkShare(kind: .nfs, server: host, share: path, mountPoint: mountPoint, endpoint: .host(host, port: 2049))
        case .webdav:
            guard let url = URLComponents(string: source), let host = url.host, !host.isEmpty else { return nil }
            let secure = url.scheme?.lowercased() == "https"
            return NetworkShare(kind: .webdav, server: host, share: decode(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), mountPoint: mountPoint,
                                endpoint: .host(host, port: url.port ?? (secure ? 443 : 80)))
        }
    }

    private static func make(kind: Kind, host: String, port: Int, share: String, mountPoint: String) -> NetworkShare {
        // "Synology._smb._tcp.local": mounted by its Bonjour name, which only Bonjour can find.
        let name = decode(host)
        if let match = name.firstMatch(of: /^(.+)\.(_[A-Za-z0-9-]+\._tcp)\.(local)\.?$/) {
            return NetworkShare(kind: kind, server: String(match.1), share: share, mountPoint: mountPoint,
                                endpoint: .bonjour(name: String(match.1), type: String(match.2), domain: String(match.3) + "."))
        }
        return NetworkShare(kind: kind, server: name, share: share, mountPoint: mountPoint, endpoint: .host(name, port: port))
    }

    /// "host", "host:139", "[fe80::1%en0]:445"
    static func hostAndPort(_ authority: String, default port: Int) -> (String, Int)? {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            return host.isEmpty ? nil : (host, after.hasPrefix(":") ? Int(after.dropFirst()) ?? port : port)
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty else { return nil }
        return (String(host), parts.count == 2 ? Int(parts[1]) ?? port : port)
    }

    private static func decode(_ text: String) -> String { text.removingPercentEncoding ?? text }
}

/// Whether a share's server answered a short connection to its file-sharing port.
public struct ShareCheck: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// The server took the connection.
        case answering
        /// The server is there but turned the connection away: file sharing is off or restarting.
        case refused
        /// No answer at all: the server is off, asleep or out of reach.
        case silent
        /// Kilobat couldn't tell, such as without Local Network access.
        case unknown
    }
    public var id: String { share.id }
    public let share: NetworkShare
    public let state: State
    public let date: Date
    /// How long the server took to answer.
    public let milliseconds: Double?
    public init(share: NetworkShare, state: State, date: Date = Date(), milliseconds: Double? = nil) {
        self.share = share; self.state = state; self.date = date; self.milliseconds = milliseconds
    }

    /// "Public on nas.local"; just "OrbStack" when the volume and its server share a name.
    public var name: String {
        share.volume.caseInsensitiveCompare(share.server) == .orderedSame ? share.volume
            : String(localized: "\(share.volume) on \(share.server)", comment: "A mounted network share: the volume's name and its server")
    }
    /// The plain answer for the CLI and the tooltip.
    public var status: String {
        switch state {
        case .answering: milliseconds.map { String(localized: "Answering (\(Int($0.rounded())) ms)", comment: "A network share's server answered; how fast") } ?? String(localized: "Answering", comment: "A network share's server answered")
        case .refused: String(localized: "Server up, sharing off", comment: "A network share's server turned the connection away")
        case .silent: String(localized: "Not answering", comment: "A network share's server doesn't answer")
        case .unknown: String(localized: "Couldn’t check", comment: "Kilobat couldn't tell whether a network share's server answers")
        }
    }
    /// What to do in a terminal, for the CLI: Finder's eject can wait on the dead server too.
    public var ejectCommand: String { "diskutil unmount force \"\(share.mountPoint)\"" }

    /// The finding for a share that went away; nil while it answers or Kilobat can't tell.
    public var finding: (title: String, detail: String, problem: Bool)? {
        switch state {
        case .silent:
            return (String(localized: "\(name) isn’t responding", comment: "Health finding: a mounted network share whose server doesn't answer"),
                    String(localized: "Finder and Save dialogs may freeze until it’s ejected.", comment: "Health finding under a network share that stopped answering; the button beside it ejects the share"),
                    true)
        case .refused:
            return (String(localized: "\(name) is up but not sharing", comment: "Health finding: a network share's server turns connections away"),
                    String(localized: "Its server refused file sharing, often while restarting. Eject it if it isn’t back in a minute.", comment: "Health finding under a network share whose server refuses connections; the button beside it ejects the share"),
                    false)
        case .answering, .unknown:
            return nil
        }
    }
}

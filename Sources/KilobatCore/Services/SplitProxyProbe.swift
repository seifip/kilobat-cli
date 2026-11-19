import Foundation

/// Opens a few secure connections at once and times each one's TCP and TLS. Nothing is requested over them, so a run
/// costs only the handshakes, and it only runs when asked: on a plane every kilobyte is someone's data allowance.
public enum SplitProxyProbe {
    static let hosts = ["www.cloudflare.com", "www.apple.com", "www.google.com", "github.com", "www.microsoft.com", "www.wikipedia.org"]
    /// A long link's handshake can take seconds; past this it counts as timed out.
    static let timeout = 12.0

    public static func measure() async -> [SplitProxyCheck.Host] {
        await withTaskGroup(of: SplitProxyCheck.Host.self) { group in
            for name in hosts {
                group.addTask { host(name, await ConnectionProbe.open(host: name, port: 443, tls: true, timeout: timeout)) }
            }
            var results: [SplitProxyCheck.Host] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.name < $1.name }
        }
    }

    static func host(_ name: String, _ attempt: ConnectionProbe.Attempt) -> SplitProxyCheck.Host {
        switch attempt.outcome {
        case .connected: SplitProxyCheck.Host(name: name, tcpMs: attempt.tcpMs, tlsMs: attempt.tlsMs, failure: attempt.tcpMs == nil || attempt.tlsMs == nil ? .other : nil)
        case .timedOut: SplitProxyCheck.Host(name: name, failure: .timeout)
        case .failed(let message) where resets.contains(message): SplitProxyCheck.Host(name: name, failure: .reset)
        case .tlsFailed(let message) where closures.contains(message): SplitProxyCheck.Host(name: name, failure: .reset)
        default: SplitProxyCheck.Host(name: name, failure: .other)
        }
    }

    /// As `ConnectionProbe.outcome` words them.
    static let resets: Set<String> = Set([ECONNRESET, ECONNABORTED, EPIPE, ENETRESET].map { String(cString: strerror($0)).lowercased() })
    /// The peer hanging up partway through the TLS handshake, as a reset does.
    static let closures: Set<String> = Set([errSSLClosedAbort, errSSLClosedNoNotify].compactMap { status in
        (SecCopyErrorMessageString(status, nil) as String?).map { $0.prefix(1).lowercased() + $0.dropFirst() }
    })
}

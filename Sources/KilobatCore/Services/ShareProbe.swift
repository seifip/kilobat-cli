import Foundation
import Network

/// Finds mounted network shares from the kernel's mount table and knocks on each server's port. `getfsstat` with
/// MNT_NOWAIT returns what the kernel has cached and never asks the server, so a dead share can't hang it; nothing
/// here touches a share's files, and nothing is ever unmounted.
public enum ShareProbe {
    public static func mounted() -> [NetworkShare] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 4
        let table = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { table.deallocate() }
        let filled = getfsstat(table, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(filled)).compactMap { index in
            var entry = table[index]
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let source = withUnsafeBytes(of: &entry.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let point = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return NetworkShare.parse(type: type, from: source, on: point)
        }
    }

    /// Every mounted share, checked at once. A server that misses the first knock gets a second, so a moment's
    /// hiccup on Wi-Fi doesn't read as a share that went away.
    public static func checkAll(_ shares: [NetworkShare] = mounted(), timeout: Double = 3) async -> [ShareCheck] {
        await withTaskGroup(of: ShareCheck.self) { group in
            for share in shares {
                group.addTask {
                    var check = await knock(share, timeout: timeout)
                    if check.state == .silent { try? await Task.sleep(for: .seconds(1)); check = await knock(share, timeout: timeout) }
                    return check
                }
            }
            var checks: [ShareCheck] = []
            for await check in group { checks.append(check) }
            return checks.sorted { $0.share.mountPoint < $1.share.mountPoint }
        }
    }

    /// One TCP connection to the share's file-sharing port, closed as soon as it opens. Nothing is sent.
    public static func knock(_ share: NetworkShare, timeout: Double = 3) async -> ShareCheck {
        let endpoint: NWEndpoint = switch share.endpoint {
        case let .host(host, port): .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 445)
        case let .bonjour(name, type, domain): .service(name: name, type: type, domain: domain, interface: nil)
        }
        // A share mounted by a bare name that DNS doesn't know ("OrbStack:/OrbStack") came through its own private channel,
        // such as a VM's file sharing: its port can't be knocked on, so a DNS failure says nothing about it.
        let bare = if case let .host(host, _) = share.endpoint { Self.bareName(host) } else { false }
        let started = ContinuousClock.now
        let connection = NWConnection(to: endpoint, using: .tcp)
        let state = await withCheckedContinuation { (continuation: CheckedContinuation<ShareCheck.State, Never>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready: once.resume(.answering)
                case let .failed(error): once.resume(connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .unknown : Self.state(error, bare: bare))
                case let .waiting(error):
                    // Waiting with a refusal is a server that's there; a denied local network is ours to fix, not the share's.
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { once.resume(.unknown) }
                    else if case .posix(.ECONNREFUSED) = error { once.resume(.refused) }
                    else if bare, case .dns = error { once.resume(.unknown) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { once.resume(.silent) }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return ShareCheck(share: share, state: state, milliseconds: state == .answering ? ms : nil)
    }

    /// "OrbStack", not "nas.local", "nas.example.com" or an address: a name only something on this Mac could resolve.
    static func bareName(_ host: String) -> Bool {
        !host.isEmpty && !host.contains(".") && !host.contains(":") && host.lowercased() != "localhost"
    }

    private static func state(_ error: NWError, bare: Bool) -> ShareCheck.State {
        switch error {
        case .posix(.ECONNREFUSED): .refused
        case .posix(.ETIMEDOUT), .posix(.EHOSTDOWN), .posix(.EHOSTUNREACH), .posix(.ENETUNREACH): .silent
        case .dns: bare ? .unknown : .silent
        default: .unknown
        }
    }

    /// Resumes the continuation the first time only: the timer and the connection race.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ShareCheck.State, Never>?
        init(_ continuation: CheckedContinuation<ShareCheck.State, Never>) { self.continuation = continuation }
        func resume(_ state: ShareCheck.State) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: state)
        }
    }
}

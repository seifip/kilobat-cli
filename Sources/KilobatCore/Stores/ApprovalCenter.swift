import Foundation
import Observation

/// Apps the filter is holding until the user allows or blocks them, and the hostnames it has seen.
/// Talks to the signed filter over the same private XPC service as the blocked-flow journal.
@MainActor @Observable public final class ApprovalCenter {
    public private(set) var pending: [PendingApproval] = []
    public private(set) var hostnames: [String: String] = [:]
    public private(set) var error: String?
    /// An app an agent or the command line asked to allow. Only the person at the Mac confirms it.
    public var requested: String?
    public init() {}

    public func poll() async {
        guard let data = await call({ service, reply in service.pendingApprovals(reply: reply) }) else { return }
        let next = (try? JSONDecoder().decode([PendingApproval].self, from: data)) ?? []
        if next != pending { pending = next }
    }

    public func refreshHostnames() async {
        guard let data = await call({ service, reply in service.hostnames(reply: reply) }),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        hostnames = names
    }

    /// Connections system services such as nsurlsessiond made for other apps, as the filter saw them.
    public private(set) var delegations: [DelegatedFlows] = []

    public func refreshDelegations() async {
        guard let data = await call({ service, reply in service.delegatedFlows(reply: reply) }) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let flows = try? decoder.decode([DelegatedFlows].self, from: data), flows != delegations else { return }
        delegations = flows
    }

    /// Releases the held connections. The caller saves the rule so later connections follow it.
    public func decide(_ app: String, allowed: Bool) async {
        pending.removeAll { $0.app == app }
        if requested == app { requested = nil }
        _ = await call({ service, reply in service.decide(app, allowed: allowed) { @Sendable decided in reply(Data([decided ? 1 : 0])) } })
    }

    public func clear() { pending = [] }

    /// XPC calls its reply and error blocks on its own queue, so they must not be main-actor closures:
    /// Swift would stop the app the moment one ran off the main thread.
    private func call(_ body: (FilterEventService, @escaping @Sendable (Data) -> Void) -> Void) async -> Data? {
        guard let team = FilterSigning.team() else { return nil }
        let client = NSXPCConnection(machServiceName: team + ".co.seifi.kilobat.filter", options: .privileged)
        client.remoteObjectInterface = NSXPCInterface(with: FilterEventService.self)
        client.setCodeSigningRequirement(FilterSigning.requirement(team: team, bundle: "co.seifi.kilobat.filter"))
        client.resume()
        defer { client.invalidate() }
        let result: Result<Data, Error> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            guard let proxy = client.remoteObjectProxyWithErrorHandler({ @Sendable error in once.resume(.failure(error)) }) as? FilterEventService else {
                once.resume(.failure(CocoaError(.featureUnsupported))); return
            }
            body(proxy) { @Sendable data in once.resume(.success(data)) }
            Task { try? await Task.sleep(for: .seconds(4)); once.resume(.failure(CocoaError(.fileReadUnknown))) }
        }
        switch result {
        case .success(let data): error = nil; return data.count <= 2_000_000 ? data : nil
        case .failure(let failure): error = failure.localizedDescription; return nil
        }
    }
}

/// Resumes a continuation exactly once, whichever of the reply, the error handler or the timeout comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Data, Error>, Never>?
    init(_ continuation: CheckedContinuation<Result<Data, Error>, Never>) { self.continuation = continuation }
    func resume(_ result: Result<Data, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Result<Data, Error>, Never>? in
            defer { continuation = nil }; return continuation
        }
        pending?.resume(returning: result)
    }
}

import Foundation
import Observation

/// Apps the filter is holding until the user allows or blocks them, and the hostnames it has seen.
/// Talks to the signed filter over the same private XPC service as the blocked-flow journal.
@MainActor @Observable public final class ApprovalCenter {
    public private(set) var pending: [PendingApproval] = []
    #if DEBUG
    /// Made-up waiting apps for screenshots; nothing reaches the filter.
    public func preview(_ items: [PendingApproval]) { previewing = true; pending = items }
    private var previewing = false
    #endif
    public private(set) var hostnames: [String: String] = [:]
    public private(set) var error: String?
    /// An app an agent or the command line asked to allow. Only the person at the Mac confirms it.
    public var requested: String?
    public init() {}

    public func poll() async {
        guard let data = await call({ service, reply in service.pendingApprovals(reply: reply) }) else { return }
        let next = (try? JSONDecoder().decode([PendingApproval].self, from: data)) ?? []
        #if DEBUG
        if previewing { return }
        #endif
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
    /// How the filter took an answer.
    public enum Outcome: Sendable, Equatable {
        case accepted
        /// The prompt changed after it was shown (a destination joined it) or is gone: nothing was released.
        case refused
        /// The filter didn't answer.
        case unreachable
    }
    /// The prompt whose answer the filter refused because it had changed; the window says so.
    public private(set) var changed: String?

    /// Releases what the answer covers, bound to the prompt's approval id and the destinations it showed. The caller
    /// saves the rule unless the filter refused the answer.
    @discardableResult public func decide(_ approval: PendingApproval, allowed: Bool, scope: ApprovalAnswer.Scope? = nil) async -> Outcome {
        let app = approval.app
        if requested == app { requested = nil }
        guard let encoded = try? JSONEncoder().encode(ApprovalAnswer(approval, allowed: allowed, scope: scope)) else { return .unreachable }
        pending.removeAll { $0.id == approval.id }
        var reply = await call({ service, reply in service.decideApproval(encoded) { @Sendable decided in reply(Data([decided ? 1 : 0])) } })
        // A filter from before approval ids only knows answers about the app.
        if reply == nil, approval.site == nil {
            reply = await call({ service, reply in service.decide(app, allowed: allowed) { @Sendable decided in reply(Data([decided ? 1 : 0])) } })
        }
        guard let reply else { return .unreachable }
        if reply == Data([1]) { if changed == approval.id { changed = nil }; return .accepted }
        changed = approval.id
        await poll()
        return .refused
    }

    public func clear() {
        #if DEBUG
        if previewing { return }
        #endif
        pending = []
    }

    /// Apps alert mode let through, as the filter keeps them; nil when it didn't answer.
    public func newApps() async -> [NewAppSighting]? {
        guard let data = await call({ service, reply in service.newApps(reply: reply) }) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([NewAppSighting].self, from: data)
    }

    /// The connection log and rule-hit counts since the last ask; nil when the filter didn't answer.
    public func connectionLog(record: Bool, browsers: Bool) async -> ConnectionLogSnapshot? {
        guard let data = await call({ service, reply in service.connectionLog(record: record, browsers: browsers, reply: reply) }) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ConnectionLogSnapshot.self, from: data)
    }

    /// The digest of the Protection index the filter has mapped; nil when the filter didn't answer.
    public func protectionDigest() async -> String? {
        await call({ service, reply in service.protectionDigest { @Sendable digest in reply(Data(digest.utf8)) } }).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Sends the filter a new Protection index. True when it checked out and the filter now uses it.
    public func installProtection(_ index: Data) async -> Bool {
        await call({ service, reply in service.installProtection(index) { @Sendable installed in reply(Data([installed ? 1 : 0])) } }) == Data([1])
    }

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

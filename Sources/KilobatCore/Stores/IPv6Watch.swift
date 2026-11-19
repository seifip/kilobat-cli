import Foundation
import Observation

/// Health's IPv6 check: reads the cheap facts on every diagnosis, opens connections on a slow schedule, and keeps the
/// readings of one network so that a failure is shown only after two in a row.
@MainActor @Observable public final class IPv6Watch {
    public private(set) var verdict: IPv6Verdict = .none
    public private(set) var checking = false
    /// A sign-in page is in the way: nothing is judged until it is dealt with.
    public private(set) var portal = false
    @ObservationIgnored private(set) var history: [IPv6Verdict] = []
    @ObservationIgnored private var network: String?
    @ObservationIgnored private var lastRun: Date?
    @ObservationIgnored var probe: (Bool) async -> IPv6Reading = { await IPv6Probe.reading(connect: $0) }
    @ObservationIgnored private var frozen = false

    public init() {}

    /// The line to show, if there is one.
    public var finding: IPv6Finding? {
        portal ? nil : IPv6Check.finding(verdict, confirmed: IPv6Check.confirmed(history))
    }

    /// `forced` is a person pressing Test again. `metered` skips the periodic runs.
    public func observe(network key: String, portal: Bool, metered: Bool, forced: Bool = false, now: Date = Date()) async {
        guard !checking, !frozen else { return }
        if key != network { network = key; history = []; lastRun = nil; verdict = .none }
        self.portal = portal
        checking = true; defer { checking = false }
        let state = await probe(false)
        guard IPv6Check.canConnect(state), !portal else { verdict = IPv6Check.verdict(state); return }
        guard IPv6Check.due(now: now, lastRun: lastRun, lastVerdict: history.last, confirmed: IPv6Check.confirmed(history), metered: metered, forced: forced) else { return }
        lastRun = now
        verdict = IPv6Check.verdict(await probe(true))
        history.append(verdict)
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    #if DEBUG
    /// Screenshots: a verdict as if it had been read twice.
    public func preview(_ sample: IPv6Verdict) { frozen = true; verdict = sample; history = [sample, sample] }
    #endif
}

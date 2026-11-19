import Foundation
import Observation

/// Drives one Fix it run: asks `FixEngine` what's next, does it with the app's actions and publishes where it is.
/// The actions are handed in, so the tests run every path with simulated readings.
@MainActor @Observable public final class FixRunner {
    public enum Phase: Equatable, Sendable {
        case measuring
        case asking(FixStep, FixLiveSession)
        case trying(FixStep)
        /// A person has this step; `acted` once they pressed its button and Kilobat is waiting for the line to recover.
        case person(FixStep, acted: Bool)
        case checking(FixStep)
        case steady(FixStep, passed: Int)
        case undoing(FixStep)
        /// Stop was pressed: putting back what the run changed.
        case stopping
        /// The run is over: putting back what was changed only for it, such as the person's DNS after a sign-in.
        case restoring
        case finished(FixOutcome)
    }
    public struct Actions {
        public var plan: @MainActor () async -> [FixStep]
        public var measure: @MainActor () async -> FixReading
        public var apply: @MainActor (FixStep) async throws -> FixUndo?
        public var undo: @MainActor (FixUndo) async throws -> Void
        public var wait: @MainActor (TimeInterval) async -> Void
        public init(plan: @escaping @MainActor () async -> [FixStep], measure: @escaping @MainActor () async -> FixReading, apply: @escaping @MainActor (FixStep) async throws -> FixUndo?,
                    undo: @escaping @MainActor (FixUndo) async throws -> Void, wait: @escaping @MainActor (TimeInterval) async -> Void) {
            self.plan = plan; self.measure = measure; self.apply = apply; self.undo = undo; self.wait = wait
        }
    }

    public let cause: FixCause
    public private(set) var phase: Phase = .measuring
    public private(set) var steps: [FixStep] = []
    public private(set) var before: FixMetric?
    public private(set) var after: FixMetric?
    public private(set) var log: [FixLogEntry] = []
    /// What was put back at the end broke the line again: the person's own DNS doesn't work on this network.
    public private(set) var restoreBroke = false
    private let actions: Actions
    private let live: FixLiveSession?
    private var answer: CheckedContinuation<Bool, Never>?
    private var stopping = false
    private var pending: FixUndo?
    private var pendingAction: FixAction?
    private var nextEntry = 0
    /// How often a step a person does is measured while waiting.
    nonisolated public static let pollEvery: TimeInterval = 6

    public init(cause: FixCause, live: FixLiveSession?, actions: Actions) {
        self.cause = cause; self.live = live; self.actions = actions
    }

    public var finished: Bool { if case .finished = phase { true } else { false } }
    public var outcome: FixOutcome? { if case .finished(let outcome) = phase { outcome } else { nil } }
    /// Changes that are still in place and can be put back.
    public var undoable: [FixLogEntry] { log.filter(\.canUndo) }

    /// The whole run. The caller keeps the task.
    public func run() async {
        let first = await actions.measure()
        if stopping { return end(.stopped(nil)) }
        before = cause.metric(first); after = nil
        // Whatever Health saw may have passed by now: then there is nothing to do.
        steps = cause.metric(first).good ? [] : await actions.plan()
        var engine = FixEngine(cause: cause, steps: steps, baseline: first, live: live)
        while !stopping {
            switch engine.command {
            case .finish(let outcome):
                await restore(after: outcome)
                return end(outcome)
            case .ask(let step, let session):
                phase = .asking(step, session)
                let yes = await personAnswers()
                if stopping { break }
                if yes { engine.allowed() } else { engine.declined(); record(step.action, .skipped) }
            case .apply(let step):
                phase = .trying(step)
                do {
                    pending = try await actions.apply(step); pendingAction = step.action
                    if stopping { break }
                    engine.applied()
                } catch {
                    record(step.action, .failed(error.localizedDescription))
                    engine.failed(error.localizedDescription)
                }
            case .person(let step):
                phase = .person(step, acted: false)
                guard await personAnswers(), !stopping else { break }
                do {
                    pending = try await actions.apply(step); pendingAction = step.action
                    engine.acted()
                } catch {
                    record(step.action, .failed(error.localizedDescription))
                    // Kilobat's part of the step didn't happen, so there's nothing for the person to wait on.
                    if step.action.undoable { engine.failed(error.localizedDescription) } else { engine.acted() }
                }
            case .measure(let step, let settle):
                if step.action.needsPerson {
                    phase = .person(step, acted: true)
                    let reading = await waitForLine(step)
                    if stopping { break }
                    judge(&engine, step, reading)
                } else {
                    phase = .checking(step)
                    await actions.wait(settle)
                    if stopping { break }
                    judge(&engine, step, await actions.measure())
                }
            case .steady(let step, let passed):
                phase = .steady(step, passed: passed)
                await actions.wait(FixPolicy.steadyInterval)
                if stopping { break }
                judge(&engine, step, await actions.measure())
            case .undo(let step):
                phase = .undoing(step)
                if let pending {
                    do { try await actions.undo(pending) } catch {
                        // Still changed, and the next step would build on it: say so and stop here.
                        record(step.action, .undoFailed(error.localizedDescription), undo: pending)
                        self.pending = nil; pendingAction = nil
                        return end(.stopped(error.localizedDescription))
                    }
                }
                record(step.action, .undone)
                pending = nil; pendingAction = nil
                engine.undone()
            }
        }
        end(.stopped(await unwind()))
    }

    /// What a person can paste into their AI agent when a step couldn't run. In English, whatever the app's language, with
    /// nothing that names the network, and the same limits Fix it keeps to.
    public func agentPrompt(appVersion: String, system: String) -> String {
        var lines = ["Kilobat's Fix it couldn't fix a network problem on my Mac. Help me find out why.", "", "Problem: \(cause.agentTitle)"]
        if let before { lines.append("Measured: \(before.text)") }
        if case .stopped(let reason?) = outcome { lines.append("Error: \(reason)") }
        if !log.isEmpty { lines += ["Tried:"] + log.map { "- \($0.action.doing): \($0.note)" } }
        lines += ["Versions: Kilobat \(appVersion), \(system)", "",
                  "To look further, run `kilobat diagnose --json`, `kilobat wifi status --json` and `kilobat dns`.", "",
                  "Find the cause first and show me what you found. Ask before changing anything. Never remove VPN profiles, wipe network settings or change the router."]
        return lines.joined(separator: "\n")
    }

    private func waitForLine(_ step: FixStep) async -> FixReading {
        var reading = await actions.measure()
        var tries = Int(step.action.patience / Self.pollEvery)
        while !cause.metric(reading).good, tries > 0, !stopping {
            tries -= 1
            await actions.wait(Self.pollEvery)
            if stopping { break }
            reading = await actions.measure()
        }
        return reading
    }

    /// Takes one reading, updates the screen and logs the engine's decision about the step.
    private func judge(_ engine: inout FixEngine, _ step: FixStep, _ reading: FixReading) {
        engine.measured(reading)
        after = cause.metric(reading)
        switch engine.decision {
        case .keep?:
            record(step.action, .kept, undo: pending)
            pending = nil; pendingAction = nil
        case .noEffect?:
            record(step.action, .noEffect)
            pending = nil; pendingAction = nil
        default: break
        }
    }

    private func personAnswers() async -> Bool {
        await withCheckedContinuation { continuation in answer = continuation }
    }
    /// The main button of the step on screen: yes to the Wi-Fi drop, or the step a person does.
    public func proceed() { answer?.resume(returning: true); answer = nil }
    /// Not now, on the Wi-Fi drop question.
    public func decline() { answer?.resume(returning: false); answer = nil }
    /// Stops the run and puts back everything it changed.
    public func stop() {
        guard !finished else { return }
        stopping = true
        phase = .stopping
        answer?.resume(returning: false); answer = nil
    }

    /// Puts back what was changed only for the run, such as the person's own DNS once they're signed in, then checks
    /// once that the line still works with it.
    private func restore(after outcome: FixOutcome) async {
        let temporary = log.indices.filter { log[$0].status == .kept && log[$0].action.restoresAfter && log[$0].undo != nil }
        guard !temporary.isEmpty else { return }
        phase = .restoring
        var restored = false
        for index in temporary {
            guard let undo = log[index].undo else { continue }
            // A restore that fails stays listed as kept, with Undo to try again.
            if (try? await actions.undo(undo)) != nil { log[index].status = .restored; log[index].undo = nil; restored = true }
        }
        guard restored, outcome == .fixed else { return }
        await actions.wait(FixAction.switchDNS(.network).settle)
        restoreBroke = !cause.metric(await actions.measure()).good
    }

    /// Puts back everything the run changed; the reason when something couldn't be.
    private func unwind() async -> String? {
        var failure: String?
        if let pending {
            do { try await actions.undo(pending) } catch {
                failure = error.localizedDescription
                if let pendingAction { record(pendingAction, .undoFailed(failure), undo: pending) }
            }
            self.pending = nil; pendingAction = nil
        }
        for index in log.indices where log[index].status == .kept {
            guard let undo = log[index].undo else { continue }
            do { try await actions.undo(undo); log[index].status = .undone; log[index].undo = nil }
            catch { failure = failure ?? error.localizedDescription; log[index].status = .undoFailed(error.localizedDescription) }
        }
        return failure
    }

    /// Puts one kept change back.
    public func undo(_ entry: FixLogEntry) async {
        guard let index = log.firstIndex(where: { $0.id == entry.id }), let undo = log[index].undo else { return }
        do {
            try await actions.undo(undo)
            log[index].status = .undone
            log[index].undo = nil
        } catch { log[index].status = .undoFailed(error.localizedDescription) }
    }

    private func record(_ action: FixAction, _ status: FixLogEntry.Status, undo: FixUndo? = nil) {
        log.append(FixLogEntry(id: nextEntry, action: action, date: Date(), status: status, undo: undo))
        nextEntry += 1
    }

    private func end(_ outcome: FixOutcome) { phase = .finished(outcome) }

    #if DEBUG
    /// A run frozen at one moment, for the debug snapshots.
    public func preview(_ phase: Phase, steps: [FixStep], before: FixMetric?, after: FixMetric?, log: [FixLogEntry] = [], restoreBroke: Bool = false) {
        self.phase = phase; self.steps = steps; self.before = before; self.after = after; self.log = log; self.restoreBroke = restoreBroke
    }
    #endif
}

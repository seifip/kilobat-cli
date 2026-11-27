import Foundation
import Observation

/// Drives the guided Bluetooth and AirDrop comparison: a reading as things are, then for each switch the person agrees
/// to, a reading with it off and another once it's back. Whatever it switched off goes back on when the run ends, is
/// stopped or a step fails. The actions are handed in, so the tests run every path on simulated readings.
@MainActor @Observable public final class RadioCheckRunner {
    public enum Phase: Equatable, Sendable {
        case measuring(RadioStage)
        /// Waiting for the person to agree to switching this off.
        case confirming(RadioSwitch)
        case switching(RadioSwitch, on: Bool)
        /// Stop was pressed: switching back what the run turned off.
        case stopping
        case finished(RadioComparison)
        case stopped
    }
    public struct Actions {
        /// One reading; nil when nothing answered.
        public var measure: @MainActor (RadioStage) async -> RadioReading?
        /// Whether each switch is on now; nil when Kilobat can't switch it.
        public var isOn: @MainActor (RadioSwitch) async -> Bool?
        public var set: @MainActor (RadioSwitch, Bool) async throws -> Void
        public var wait: @MainActor (TimeInterval) async -> Void
        public init(measure: @escaping @MainActor (RadioStage) async -> RadioReading?, isOn: @escaping @MainActor (RadioSwitch) async -> Bool?,
                    set: @escaping @MainActor (RadioSwitch, Bool) async throws -> Void, wait: @escaping @MainActor (TimeInterval) async -> Void) {
            self.measure = measure; self.isOn = isOn; self.set = set; self.wait = wait
        }
    }

    public private(set) var phase: Phase = .measuring(.asIs)
    public private(set) var readings: [RadioStage: RadioReading] = [:]
    /// The switches this run can test, in order.
    public private(set) var radios: [RadioSwitch] = []
    public private(set) var error: String?
    private let actions: Actions
    private let channel: Int?, band: String?
    private var answer: CheckedContinuation<Bool, Never>?
    private var stopping = false
    /// Switched off by this run and not yet back on.
    public private(set) var switchedOff: Set<RadioSwitch> = []

    public init(channel: Int? = nil, band: String? = nil, actions: Actions) {
        self.channel = channel; self.band = band; self.actions = actions
    }

    public var finished: Bool {
        switch phase { case .finished, .stopped: true; default: false }
    }
    public var result: RadioComparison? { if case .finished(let result) = phase { result } else { nil } }

    public func run() async {
        var skipped: [RadioSwitch: RadioSkip] = [:]
        for radio in RadioSwitch.allCases {
            switch await actions.isOn(radio) {
            case true?: radios.append(radio)
            case false?: skipped[radio] = .alreadyOff
            case nil: skipped[radio] = .unavailable
            }
            if stopping { return await halt() }
        }
        guard !radios.isEmpty else { return end(RadioComparison(effects: [], skipped: skipped, channel: channel, band: band)) }
        phase = .measuring(.asIs)
        guard let first = await actions.measure(.asIs), !stopping else { return await halt() }
        readings[.asIs] = first
        var effects: [RadioEffect] = []
        var reference = first
        for radio in radios {
            let yes = await personAnswers(for: radio)
            if stopping { return await halt() }
            guard yes else { skipped[radio] = .declined; continue }
            phase = .switching(radio, on: false)
            do { try await actions.set(radio, false); switchedOff.insert(radio) }
            catch { skipped[radio] = .failed; self.error = error.localizedDescription }
            if stopping { return await halt() }
            guard skipped[radio] != .failed else { continue }
            await actions.wait(radio.settle)
            if stopping { return await halt() }
            phase = .measuring(.off(radio))
            let off = await actions.measure(.off(radio))
            if stopping { return await halt() }
            phase = .switching(radio, on: true)
            await restore(radio)
            await actions.wait(radio.settle)
            if stopping { return await halt() }
            phase = .measuring(.back(radio))
            let back = await actions.measure(.back(radio))
            if stopping { return await halt() }
            guard let off else { skipped[radio] = .failed; continue }
            readings[.off(radio)] = off
            if let back { readings[.back(radio)] = back }
            effects.append(RadioComparison.effect(radio, before: reference, off: off, back: back))
            // The next switch is judged against the line as it is now.
            reference = back ?? reference
        }
        // One more try at anything that didn't come back on.
        for radio in RadioSwitch.allCases { await restore(radio) }
        end(RadioComparison(effects: effects, skipped: skipped, channel: channel, band: band))
    }

    /// Yes to switching the radio on screen off.
    public func proceed() { answer?.resume(returning: true); answer = nil }
    /// Not this one: skip it and go on.
    public func skip() { answer?.resume(returning: false); answer = nil }
    /// Stops the run; whatever it switched off goes back on.
    public func stop() {
        guard !finished else { return }
        stopping = true
        phase = .stopping
        answer?.resume(returning: false); answer = nil
    }

    private func personAnswers(for radio: RadioSwitch) async -> Bool {
        await withCheckedContinuation { continuation in
            guard !stopping else { return continuation.resume(returning: false) }
            answer = continuation
            phase = .confirming(radio)
        }
    }
    private func restore(_ radio: RadioSwitch) async {
        guard switchedOff.contains(radio) else { return }
        do { try await actions.set(radio, true); switchedOff.remove(radio) }
        catch { self.error = error.localizedDescription }
    }
    private func halt() async {
        phase = .stopping
        for radio in RadioSwitch.allCases { await restore(radio) }
        phase = .stopped
    }
    private func end(_ result: RadioComparison) {
        phase = .finished(result)
    }

    #if DEBUG
    /// A run frozen at one moment, for the debug snapshots.
    public func preview(_ phase: Phase, radios: [RadioSwitch], readings: [RadioStage: RadioReading] = [:]) {
        self.phase = phase; self.radios = radios; self.readings = readings
    }
    #endif
}

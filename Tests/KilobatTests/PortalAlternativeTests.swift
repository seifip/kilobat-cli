import Foundation
import Testing
@testable import KilobatCore

@MainActor struct PortalAlternativeTests {
    @Test func requiresRepeatedFailuresAndWorkingInternet() {
        let watch = PortalAlternative()
        watch.context(network: "test-a", identified: true, wifi: true, reachable: true)
        let time = Date()
        watch.observe(PortalCheck(state: .offline), normal: true, reachable: true, wifi: true, now: time)
        #expect(watch.state == .hidden)
        watch.observe(PortalCheck(state: .offline), normal: true, reachable: true, wifi: true, now: time.addingTimeInterval(31))
        #expect(watch.state == .suggested)
        watch.context(network: "test-a", identified: true, wifi: true, reachable: false)
        #expect(watch.state == .hidden)
    }
    @Test func explicitTrialThenRememberOnlyThisNetwork() async {
        let suite = "PortalAlternativeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let watch = PortalAlternative(defaults: defaults)
        watch.context(network: "a", identified: true, wifi: true, reachable: true)
        for offset in [0.0, 31.0] { watch.observe(PortalCheck(state: .offline), normal: true, reachable: true, wifi: true, now: Date().addingTimeInterval(offset)) }
        await watch.tryOnce { PortalCheck(state: .open) }
        #expect(watch.state == .worked)
        #expect(!watch.enabled(for: "a", identified: true))
        watch.remember()
        #expect(watch.enabled(for: "a", identified: true))
        #expect(!watch.enabled(for: "b", identified: true))
        #expect(!watch.enabled(for: "a", identified: false))
        watch.forgetCurrentNetwork()
        #expect(!watch.enabled(for: "a", identified: true))
    }
    @Test func dismissalAndNetworkChangesInvalidateTrial() async {
        let watch = PortalAlternative()
        watch.context(network: "a", identified: false, wifi: true, reachable: true)
        for offset in [0.0, 31.0] { watch.observe(PortalCheck(state: .offline), normal: true, reachable: true, wifi: true, now: Date().addingTimeInterval(offset)) }
        #expect(!watch.canRemember)
        watch.dismiss()
        watch.observe(PortalCheck(state: .offline), normal: true, reachable: true, wifi: true, now: Date().addingTimeInterval(90))
        #expect(watch.state == .hidden)
        watch.context(network: "b", identified: true, wifi: true, reachable: true)
        for offset in [0.0, 31.0] { watch.observe(PortalCheck(state: .offline), normal: true, reachable: true, wifi: true, now: Date().addingTimeInterval(offset)) }
        let task = Task { await watch.tryOnce { try? await Task.sleep(for: .milliseconds(50)); return PortalCheck(state: .open) } }
        while watch.state != .checking { await Task.yield() }
        watch.context(network: "c", identified: true, wifi: true, reachable: true)
        await task.value
        #expect(watch.state == .hidden)
    }
}

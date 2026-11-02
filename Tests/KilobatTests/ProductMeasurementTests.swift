import Foundation
import Testing
@testable import KilobatCore

@MainActor private final class MeasurementWire {
    var requests: [URLRequest] = []
    var offline = false
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let body = request.url!.lastPathComponent == "consent" ? "{\"distinct_id\":\"11111111-1111-4111-a111-111111111111\"}" : "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor private func fixture(allowed: Bool = true) -> (ProductMeasurement, MeasurementWire, UserDefaults) {
    let defaults = UserDefaults(suiteName: "measurement-test-" + UUID().uuidString)!
    let wire = MeasurementWire()
    return (ProductMeasurement(defaults: defaults, endpoint: URL(string: "https://example.invalid/api/measurement")!, version: "1.17.0", language: "en", allowed: allowed, transport: wire.send), wire, defaults)
}
@MainActor private func settleTasks() async { for _ in 0..<30 { await Task.yield() } }

@Test @MainActor func measurementDefaultOffAndInternalBuildsStayOff() async {
    let (client, wire, _) = fixture()
    client.resume(); client.meaningful("diagnosis"); client.event("upgrade_intent")
    await settleTasks(); #expect(wire.requests.isEmpty)
    let (internalClient, internalWire, _) = fixture(allowed: false)
    internalClient.setEnabled(true); internalClient.meaningful("diagnosis")
    await settleTasks(); #expect(internalWire.requests.isEmpty); #expect(!internalClient.enabled)
}
@Test @MainActor func measurementConsentCheckoutAndWithdrawal() async {
    let (client, wire, defaults) = fixture()
    let checkout = URL(string: "https://checkout.dodopayments.com/buy?metadata_referral=abc123")!
    #expect(client.checkout(checkout) == checkout)
    client.setEnabled(true); await settleTasks()
    #expect(client.distinctID != nil)
    client.attribution(source: "github", campaign: "agents")
    client.answerUseCase(["ai_coding", "vpn_proxy"]); client.meaningful("diagnosis"); client.meaningful("diagnosis")
    await settleTasks()
    let url = client.checkout(checkout).absoluteString
    #expect(url.contains("metadata_referral=abc123")); #expect(url.contains("metadata_analytics_id=")); #expect(url.contains("metadata_source=github"))
    let features = wire.requests.filter { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("feature_used") == true }
    #expect(features.count == 1)
    client.setEnabled(false); await settleTasks()
    #expect(!client.enabled); #expect(client.distinctID == nil); #expect(client.checkout(checkout) == checkout)
    #expect(defaults.bool(forKey: "measurement.invitationSeen"))
    #expect(defaults.string(forKey: "measurement.token") == nil)
    #expect(wire.requests.contains { $0.url?.lastPathComponent == "withdraw" })
    let before = wire.requests.count; client.meaningful("diagnosis"); await settleTasks(); #expect(wire.requests.count == before)
}
@Test @MainActor func measurementOfflineWithdrawalPersistsWithoutProductEvents() async {
    let (client, wire, defaults) = fixture()
    client.setEnabled(true); await settleTasks(); wire.offline = true
    client.setEnabled(false); await settleTasks()
    #expect(client.deletionPending); #expect(defaults.string(forKey: "measurement.withdrawToken") != nil)
    let before = wire.requests.count; client.event("upgrade_intent"); await settleTasks(); #expect(wire.requests.count == before)
    wire.offline = false; await client.retryWithdrawal()
    #expect(!client.deletionPending); #expect(defaults.string(forKey: "measurement.withdrawToken") == nil)
}

@Test @MainActor func measurementLateRegistrationCannotRestoreWithdrawnConsent() async {
    let defaults = UserDefaults(suiteName: "measurement-race-" + UUID().uuidString)!
    var release: CheckedContinuation<Void, Never>?
    var productEvents = 0
    let client = ProductMeasurement(defaults: defaults, endpoint: URL(string: "https://example.invalid/api/measurement")!, version: "1.17.0", language: "en") { request in
        if request.url?.lastPathComponent == "consent" {
            await withCheckedContinuation { release = $0 }
        }
        if request.url?.lastPathComponent == "event" { productEvents += 1 }
        let body = request.url?.lastPathComponent == "consent" ? "{\"distinct_id\":\"11111111-1111-4111-a111-111111111111\"}" : "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    client.setEnabled(true); await settleTasks()
    #expect(release != nil)
    client.meaningful("diagnosis")
    #expect(!defaults.bool(forKey: "measurement.activated"))
    client.setEnabled(false); await settleTasks()
    release?.resume(); await settleTasks()
    #expect(!client.enabled); #expect(client.distinctID == nil); #expect(productEvents == 0)
}

@Test @MainActor func measurementOfflineActivationRetriesWithTheSameEventID() async {
    let (client, wire, defaults) = fixture()
    client.setEnabled(true); await settleTasks()
    wire.offline = true; client.meaningful("diagnosis"); await settleTasks()
    #expect(!defaults.bool(forKey: "measurement.activated"))
    wire.offline = false; client.meaningful("budget"); await settleTasks()
    #expect(defaults.bool(forKey: "measurement.activated"))
    let attempts = wire.requests.compactMap { request -> [String: Any]? in
        guard let data = request.httpBody, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["event"] as? String == "meaningful_activation" else { return nil }
        return body
    }
    #expect(attempts.count == 2)
    #expect(attempts.first?["id"] as? String == attempts.last?["id"] as? String)
}

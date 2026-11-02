#if DEBUG
import Foundation

/// Made-up answers for the Siri snippet screenshots (KILOBAT_DEBUG_SIRI=1 with KILOBAT_SNAPSHOT): no real network, app or call.
public enum SiriSamples {
    public static func answers(now: Date = Date()) -> [(name: String, answer: SiriAnswer)] {
        func sample(_ date: Date, rssi: Int = -52, router: Double = 3, internet: [Double] = [21, 23, 22], loss: Double = 0) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: date, radio: RadioSample(ssid: "Home", interface: "en0", rssi: rssi, noise: -92, transmitMbps: 600, channel: 149, band: "5 GHz"),
                               gateway: "192.168.1.1", router: PingResult(host: "router", samples: [router, router], lossPercent: 0),
                               internet: PingResult(host: "1.1.1.1", samples: internet, lossPercent: loss), dnsMilliseconds: 19, dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        }
        let history = (0..<120).map { minute -> DiagnosticSnapshot in
            let date = now.addingTimeInterval(Double(minute - 120) * 60)
            return sample(date, internet: [34, 38, 31], loss: minute >= 30 ? (minute % 2 == 0 ? 5 : 3) : 0)
        }
        let provider = SiriAnswers.diagnosis(NetworkDiagnosisInput(snapshot: sample(now, internet: [34, 38, 31], loss: 4), history: history, now: now), pro: true).answer
        let free = SiriAnswers.diagnosis(NetworkDiagnosisInput(snapshot: sample(now, rssi: -79, internet: [140, 150], loss: 6), now: now), pro: false).answer
        let fine = SiriAnswers.diagnosis(NetworkDiagnosisInput(snapshot: sample(now), now: now), pro: true).answer
        var samples = CallSamples()
        samples.internet = (0..<600).map { CallSamples.Ping(at: Double($0), ms: [140, 141, 142, 300, 301].contains($0) ? nil : 30) }
        samples.router = (0..<600).map { CallSamples.Ping(at: Double($0), ms: 3) }
        samples.traffic = [.init(at: 139, app: "Dropbox", upload: 1_400_000, download: 0), .init(at: 299, app: "Dropbox", upload: 1_100_000, download: 0)]
        let call = CallAnalysis.report(app: "Zoom", browser: false, start: now.addingTimeInterval(-3000), end: now.addingTimeInterval(-600), network: nil, samples: samples)
        let slack = ServiceStatus(id: "slack", service: "Slack", state: .majorOutage, incident: "Messages failing to send", started: now.addingTimeInterval(-1800),
                                  page: URL(string: "https://slack-status.com")!, checked: now)
        let zoom = ServiceStatus(id: "zoom", service: "Zoom", state: .operational, page: URL(string: "https://status.zoom.us")!, checked: now)
        let apps = [BusyApp(name: "Steam", download: 8_400_000, upload: 20_000), BusyApp(name: "Dropbox", download: 0, upload: 1_200_000), BusyApp(name: "Safari", download: 300_000, upload: 4_000)]
        return [("Diagnosis", provider), ("DiagnosisFree", free), ("DiagnosisFine", fine),
                ("Call", SiriAnswers.call(call, pro: true, now: now)), ("CallFree", SiriAnswers.call(call, pro: false, now: now)),
                ("Service", SiriAnswers.services([slack, zoom], lineFine: true)),
                ("UsageNow", SiriAnswers.usageNow(apps, download: 8_700_000, upload: 1_224_000)),
                ("DataUsed", SiriAnswers.dataUsed(received: 2_900_000_000, sent: 310_000_000, topApps: ["Steam", "Safari"],
                                                  budget: .init(used: 4_100_000_000, limitGB: 5, cycle: BudgetCycle(period: .monthly)), now: now)),
                ("Ready", SiriAnswers.preflight(Preflight(date: now, issues: [.init(kind: .app, app: "Dropbox", uploading: true), .init(kind: .wifi)]), pro: false))]
    }
}
#endif

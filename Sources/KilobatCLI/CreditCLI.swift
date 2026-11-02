import Foundation
import KilobatCore

/// `kilobat credit`: the month's outages beyond the router, the provider's credit rule and a drafted claim. Read-only:
/// the provider and price come from the app (History › Outage credit) unless flags give them for this run.
@MainActor enum CreditCLI {
    static func report(_ options: CreditOptions, now: Date = Date()) -> CreditReport {
        var settings = CreditSettings.load(KilobatCLI.appDefaults) ?? CreditSettings()
        if let provider = options.provider { settings.provider = provider }
        if let country = options.country { settings.country = country; if options.provider == nil { settings.provider = nil } }
        if let price = options.price { settings.monthlyPrice = price }
        let journal = NetworkJournal()
        return CreditReport.make(settings: settings, events: journal.events, samples: journal.samples, dish: StarlinkJournal.load(),
                                 sleeps: CreditReport.sleeps(), interval: options.interval(now: now), now: now)
    }

    static func run(_ args: [String]) throws {
        let options: CreditOptions
        do { options = try CreditOptions.parse(args) } catch { throw CLIError(error.localizedDescription) }
        if options.list { try providers(country: options.listCountry, json: options.json); return }
        let report = report(options)
        if options.json { print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self)); return }
        if options.draft { print(report.claim.text); return }
        let tally = report.tally
        print("Outage credit · \(tally.from.formatted(.dateTime.month(.wide).year()))" + (tally.network.map { " · \($0)" } ?? ""))
        if report.provider == nil && report.country == nil {
            print("Provider: not set. Pick yours in Kilobat › History › Outage credit, or pass --provider (kilobat credit providers lists them).")
        } else {
            print("Provider: \(report.providerName)" + (report.policy.map { " · \($0.name)" } ?? ""))
        }
        if let longest = tally.longest {
            print("Beyond the router: \(tally.outages.count) outage\(tally.outages.count == 1 ? "" : "s"), \(CreditText.duration(tally.totalSeconds)) in all; longest \(CreditText.duration(longest.seconds)) from \(CreditText.span(longest))")
        } else {
            print("Beyond the router: no outages recorded in this month.")
        }
        if let excluded = report.excluded { print(excluded) }
        if let terms = report.terms { print("Rule: \(terms)") }
        print(report.verdict)
        if let policy = report.policy { print("Source: \(policy.source) (checked \(policy.checked))") }
        if let note = report.provider?.note { print("Note: \(note)") }
        let ask = [report.claimURL?.absoluteString, report.phone].compactMap { $0 }
        if !ask.isEmpty { print("Ask: " + ask.joined(separator: " · ")) }
        if let askBy = report.estimate.askBy { print("Ask by \(askBy.formatted(date: .long, time: .omitted)).") }
        if tally.outages.count > 1 {
            print("Outages:")
            for outage in tally.outages.suffix(15) { print("  • " + CreditText.span(outage)) }
        }
        if !tally.outages.isEmpty { print("\nkilobat credit --draft prints a message to send. Kilobat never sends it; attach kilobat support-report --html --output report.html.") }
    }

    static func providers(country: String?, json: Bool) throws {
        let table = OutageCreditTable.bundled
        let list = country.map { code in table.providers.filter { $0.country == code || $0.country == nil } } ?? table.providers
        let laws = table.policies.filter { $0.national && $0.appliesToAll == true && (country == nil || $0.country == country) }
        if json {
            struct Output: Encodable { let updated: String; let providers: [CreditProvider]; let policies: [CreditPolicy] }
            let ids = Set(list.compactMap(\.policy)).union(laws.map(\.id))
            print(String(decoding: try DiagnosticsCLI.encode(Output(updated: table.updated, providers: list, policies: table.policies.filter { ids.contains($0.id) })), as: UTF8.self))
            return
        }
        print("Outage-credit rules checked \(table.updated)")
        for provider in list {
            let rule = table.policy(id: provider.policy)?.name ?? "no published rule Kilobat could verify"
            print("  \(KilobatCLI.pad(provider.id, 18))\(KilobatCLI.pad(provider.name, 24))\(KilobatCLI.pad(provider.country ?? "—", 4))\(rule)")
        }
        for law in laws { print("  Every provider in \(law.country ?? "—"): \(law.name)") }
    }
}

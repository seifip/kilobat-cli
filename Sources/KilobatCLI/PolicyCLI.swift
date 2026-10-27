import Foundation
import KilobatCore

@MainActor enum PolicyCLI {
    static func run(_ args: [String]) async throws {
        let store = TrafficStore(startMonitoring: false)
        switch args.first {
        case "blocklist":
            guard args.count >= 2 else { throw CLIError("Use blocklist <status|import path|clear>.") }
            switch args[1] {
            case "status": print("\(store.preferences.blockedDomains?.count ?? 0) domains · \(store.preferences.blocklistName ?? "No list")")
            case "clear": store.preferences.blockedDomains = nil; store.preferences.blocklistName = nil; print("List removed.")
            case "import":
                guard args.count == 3 else { throw CLIError("Use blocklist import <plain-list-path>.") }
                let url = URL(fileURLWithPath: args[2]); let domains = try DomainPolicy.parseList(Data(contentsOf: url))
                store.preferences.blockedDomains = domains; store.preferences.blocklistName = url.lastPathComponent
                print("Imported \(domains.count) domains. Enforcement requires an active signed extension.")
            default: throw CLIError("Use blocklist <status|import path|clear>.")
            }
        case "domain-exception":
            guard args.count == 3 else { throw CLIError("Use domain-exception <app-bundle-id> <domain>.") }
            let domains = try DomainPolicy.parseList(Data(args[2].utf8))
            var exceptions = store.preferences.domainExceptions ?? [:]
            exceptions[args[1]] = Array(Set((exceptions[args[1]] ?? []) + domains)).sorted(); store.preferences.domainExceptions = exceptions
            print("Exception saved; requires an active signed filter.")
        case "remember-network":
            guard args.count == 1 else { throw CLIError("Use remember-network with no arguments.") }
            let profile = store.preferences.profile, budget = store.preferences.limitGB
            store.switchNetwork(await DiagnosticProbe().snapshot())
            store.preferences.profile = profile; store.preferences.limitGB = budget; store.rememberNetwork()
            print("Remembered \(profile.rawValue), \(budget) GB for \(store.networkName).")
        case "scope":
            guard args.count == 2, ["external", "wifi", "wired"].contains(args[1]) else { throw CLIError("Use scope <external|wifi|wired>.") }
            store.preferences.trafficScope = args[1]; print("Saved scope: \(args[1]). Open Kilobat reloads it on its next sample.")
        default: throw CLIError("Unknown policy command.")
        }
    }
}

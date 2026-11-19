import Foundation
import KilobatCore

/// `kilobat restrictions --country XX`: what public reports expect in a country, from the shared snapshot.
/// Read-only. Not a live probe, and not a replacement for NetworkBlockCheck.
enum RestrictionsCLI {
    static let usage = "Use restrictions --country XX [--json]. XX is an ISO country code."

    static func run(_ args: [String]) throws {
        var country: String?
        var json = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
                index += 1
            case "--country":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw CLIError(usage) }
                country = args[index + 1]
                index += 2
            default:
                throw CLIError(usage)
            }
        }
        guard let country else { throw CLIError(usage) }
        let report: ExpectedRestrictions.CountryReport
        do { report = try ExpectedRestrictions.country(country) } catch {
            throw CLIError(error.localizedDescription)
        }
        if json {
            print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self))
            return
        }
        print(report.text)
    }
}

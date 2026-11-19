import Foundation
import Security

/// A developer's name for a rule's label.
public enum DeveloperName {
    /// From the signer the filter reports ("Developer ID Application: Example Inc (AB12CD34EF) · AB12CD34EF"): Example Inc.
    /// Falls back to "Team AB12CD34EF".
    public static func name(signer: String?, team: String?) -> String {
        var subject = signer?.components(separatedBy: " · ").first ?? ""
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: ", "Mac Developer: ", "3rd Party Mac Developer Application: "] where subject.hasPrefix(prefix) {
            subject.removeFirst(prefix.count)
        }
        if let team, subject.hasSuffix(" (\(team))") { subject.removeLast(team.count + 3) }
        subject = subject.trimmingCharacters(in: .whitespaces)
        if !subject.isEmpty, subject != team { return subject }
        return team.map { String(localized: "Team \($0)", comment: "A developer known only by its Team ID") } ?? String(localized: "this developer")
    }
}

extension DeveloperRule {
    /// Keeps a developer's name for its rule, unless it's only the Team ID fallback.
    public static func remember(_ name: String, team: String, in preferences: inout SavedPreferences) {
        guard !name.isEmpty, !name.hasSuffix(team) else { return }
        var names = preferences.developerNames ?? [:]
        names[team] = name
        preferences.developerNames = names
    }
    /// "Example Inc" when Kilobat knows the name, else "Team AB12CD34EF".
    public static func displayName(team: String, preferences: SavedPreferences) -> String {
        preferences.developerNames?[team] ?? String(localized: "Team \(team)", comment: "A developer known only by its Team ID")
    }

    /// The Team ID an app on disk is signed with, from its signature (not checked against Apple's root here: the
    /// filter does that before a rule applies). Nil for unsigned, ad-hoc and Apple platform code.
    public static func team(atPath path: String) -> String? {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, valid(team) else { return nil }
        return team
    }

    /// The Team ID and the developer's name ("Example Inc") from the code signature at a path.
    public static func developer(atPath path: String) -> (team: String, name: String)? {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any], let team = fields[kSecCodeInfoTeamIdentifier as String] as? String, valid(team) else { return nil }
        let leaf = (fields[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return (team, DeveloperName.name(signer: summary, team: team))
    }
}

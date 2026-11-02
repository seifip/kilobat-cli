import Foundation
import KilobatCore

/// `kilobat explain <process|host…> [--json]`: what a macOS process or an internet host is, whether it's safe to block
/// and what breaks, from Kilobat's own database (the same one as kilobat.app/processes and /hosts). Looked up on this
/// Mac; nothing is sent anywhere. A name the database doesn't know gets the facts Kilobat has instead.
enum ExplainCLI {
    static func run(_ args: [String]) async throws {
        let parsed: (queries: [ExplainQuery], json: Bool)
        do { parsed = try ExplainQuery.parse(args) } catch { throw CLIError(error.localizedDescription) }
        let (queries, json) = parsed
        let explainer = Explainer.shared
        guard explainer.available else {
            throw CLIError("Kilobat's explainer database isn't installed. It comes with the Kilobat app, in /Applications/Kilobat.app.")
        }
        let explanations = queries.map { explainer.explain(subject($0)) }
        if json { print(String(decoding: try encode(explanations), as: UTF8.self)); return }
        print(explanations.map(text).joined(separator: "\n\n"))
    }

    static func subject(_ query: ExplainQuery) -> ExplainSubject {
        var subject = query.subject
        if let path = subject.path { subject.signer = Explainer.signer(path: path) }
        return subject
    }

    /// JSON for scripts and agents, the same as the explain_connection MCP tool: one object per question.
    static func encode(_ explanations: [Explanation]) throws -> Data {
        let rows = explanations.map(row)
        return try JSONSerialization.data(withJSONObject: rows.count == 1 ? rows[0] : ["results": rows] as Any, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func row(_ explanation: Explanation) -> [String: Any] {
        var row: [String: Any] = ["known": !explanation.unknown, "source": "Kilobat's explainer database, on this Mac"]
        if let p = explanation.process {
            row["process"] = ["slug": p.slug, "name": p.name, "aliases": p.aliases, "maker": p.maker, "category": p.category, "summary": p.summary,
                              "normal": p.normal, "heavyWhen": p.heavy, "safeToBlock": p.verdict.rawValue, "blocking": p.block, "breaks": p.breaks,
                              "reduce": p.reduce, "paths": p.paths, "identifiers": p.ids, "hosts": p.hosts, "url": p.url.absoluteString, "checked": p.checked]
        }
        if let h = explanation.host {
            row["host"] = ["slug": h.slug, "host": h.host, "match": h.match, "owner": h.owner, "category": h.category, "summary": h.summary,
                           "safeToBlock": h.verdict.rawValue, "blocking": h.block, "breaks": h.breaks, "processes": h.processes,
                           "url": h.url.absoluteString, "checked": h.checked]
        }
        let facts = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(explanation.facts))) as? [String: Any] ?? [:]
        if !facts.isEmpty { row["facts"] = facts }
        if explanation.unknown {
            row["note"] = "Not in Kilobat's database. These are the facts Kilobat has; it doesn't guess. The Kilobat app can add an on-device best guess on macOS 26 or later."
        }
        return row
    }

    static func text(_ explanation: Explanation) -> String {
        var lines: [String] = []
        if let p = explanation.process {
            lines.append("\(Terminal.bold(p.name))  \(Terminal.dim("· " + p.maker))")
            lines.append(p.summary)
            lines.append("Normal: " + p.normal)
            if !p.heavy.isEmpty { lines.append("Uses a lot when: " + p.heavy.joined(separator: "; ") + ".") }
            lines.append(verdictLine(p.verdict, p.block))
            lines += p.breaks.map { "  • " + $0 }
            lines.append("Reduce it: " + p.reduce)
            lines.append(Terminal.dim(p.url.absoluteString))
        }
        if let h = explanation.host {
            if !lines.isEmpty { lines.append("") }
            lines.append("\(Terminal.bold(h.host))  \(Terminal.dim("· " + h.owner))")
            lines.append(h.summary)
            lines.append(verdictLine(h.verdict, h.block))
            lines += h.breaks.map { "  • " + $0 }
            lines.append(Terminal.dim(h.url.absoluteString))
        }
        if explanation.unknown {
            let f = explanation.facts
            let name = f.process ?? f.identifier ?? f.path ?? f.host ?? f.address ?? "?"
            lines.append("\(Terminal.bold(name)) isn't in Kilobat's database. What Kilobat knows:")
            let facts: [(String, String?)] = [("Path", f.path), ("Identifier", f.identifier), ("Signed by", f.signer), ("Where it lives", f.kind),
                                              ("Host", f.host), ("Address", f.address), ("Network", f.network), ("Country", f.country)]
            lines += facts.compactMap { label, value in value.map { "  \(label): \($0)" } }
            lines.append(Terminal.dim("Search kilobat.app/processes and kilobat.app/hosts, or ask the Kilobat app for an on-device best guess."))
        }
        return lines.joined(separator: "\n")
    }

    static func verdictLine(_ verdict: ExplainerVerdict, _ summary: String) -> String {
        let mark = switch verdict { case .safe: Terminal.green("✓"); case .caution: Terminal.violet("!"); case .avoid: Terminal.rose("✗") }
        return "\(mark) \(summary) \(Terminal.dim("(" + verdict.label + ")"))"
    }
}

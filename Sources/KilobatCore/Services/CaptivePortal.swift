import Foundation

/// One look for a Wi-Fi sign-in page (a captive portal), the way macOS and Android look: Apple's check page, then
/// Google's when Apple's can't be reached. Two small HTTP requests to those hosts only; redirects aren't followed.
public struct PortalCheck: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// The check page came through: the internet is reachable and nothing is in the way.
        case open
        /// Something answered for the check page with a redirect or a page of its own: a sign-in page.
        case portal
        /// Neither check page answered at all.
        case offline
    }
    public let state: State
    public let date: Date
    /// The sign-in page, from the redirect, a meta refresh or a script; nil when the page didn't say.
    public var url: URL? = nil
    /// A length of sign-in the page itself states, such as "1 hour of free Wi-Fi", in minutes.
    public var hintMinutes: Int? = nil
    public init(state: State, date: Date = Date(), url: URL? = nil, hintMinutes: Int? = nil) {
        self.state = state; self.date = date; self.url = url; self.hintMinutes = hintMinutes
    }
    public var host: String? { url?.host?.lowercased() }
}

public enum CaptivePortal {
    public enum Endpoint: String, Sendable, CaseIterable {
        case apple = "http://captive.apple.com/hotspot-detect.html"
        case google = "http://connectivitycheck.gstatic.com/generate_204"
        public var url: URL { URL(string: rawValue)! }
    }
    /// What one check page's answer says.
    public enum Answer: Equatable, Sendable {
        case success
        case intercepted(URL?)
        case failed
    }

    /// Apple's page is a 200 with "Success" in its title; Google's is an empty 204, and like Android an empty 200
    /// counts too. Anything else that answered, a redirect or a page of its own, is a sign-in page in the way.
    public static func classify(_ endpoint: Endpoint, status: Int?, body: String, location: String?) -> Answer {
        guard let status else { return .failed }
        let success = switch endpoint {
        case .apple: status == 200 && body.range(of: "<title>success</title>", options: .caseInsensitive) != nil
        case .google: status == 204 || (status == 200 && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if success { return .success }
        return .intercepted(signInPage(location: location, body: body, base: endpoint.url))
    }

    /// The sign-in page's address: the redirect's Location, else a meta refresh or a script that sets the location.
    /// Only http and https, resolved against the check page.
    public static func signInPage(location: String?, body: String, base: URL) -> URL? {
        func web(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
            guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
        if let location, let url = web(location) { return url }
        let patterns = [
            #"(?i)<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["']?\s*\d*\s*;?\s*url\s*=\s*['"]?([^"'>\s]+)"#,
            #"(?i)<meta[^>]+content\s*=\s*["']?\s*\d*\s*;?\s*url\s*=\s*['"]?([^"'>\s]+)[^>]*http-equiv\s*=\s*["']?refresh"#,
            #"(?i)(?:window|document|top|self)?\.?location(?:\.href)?\s*=\s*["']([^"']+)["']"#,
            #"(?i)location\.(?:replace|assign)\(\s*["']([^"']+)["']\s*\)"#,
        ]
        for pattern in patterns {
            if let match = DiagnosticProbe.matches(pattern, in: body).first, let url = web(match) { return url }
        }
        return nil
    }

    /// A length the sign-in page states, such as "1 hour of free Wi-Fi" or "60 minutes per session", in minutes.
    /// English only, and only when the page names exactly one length near a word about access; a price list of
    /// plans names several and gives nil.
    public static func hint(in body: String) -> Int? {
        let text = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(\d{1,4})[\s-]*(hours?|hrs?|minutes?|mins?)\b"#) else { return nil }
        let context = ["session", "access", "free", "internet", "wifi", "wi-fi", "valid", "expire", "limit", "connect", "online", "browsing"]
        var found = Set<Int>()
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[numberRange]), let whole = Range(match.range, in: text) else { continue }
            let minutes = text[unitRange].lowercased().hasPrefix("h") ? number * 60 : number
            guard (15...1440).contains(minutes) else { continue }
            let start = text.index(whole.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(whole.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            let around = text[start..<end].lowercased()
            if context.contains(where: around.contains) { found.insert(minutes) }
        }
        return found.count == 1 ? found.first : nil
    }

    /// Apple's page first; Google's only when Apple's didn't answer. When Apple's answered with something else,
    /// that's what macOS sees too, so it decides.
    public static func check(timeout: TimeInterval = 5) async -> PortalCheck {
        let apple = await fetch(.apple, timeout: timeout)
        switch apple.answer {
        case .success: return PortalCheck(state: .open)
        case .intercepted(let url): return PortalCheck(state: .portal, url: url, hintMinutes: hint(in: apple.body))
        case .failed:
            let google = await fetch(.google, timeout: timeout)
            switch google.answer {
            case .success: return PortalCheck(state: .open)
            case .intercepted(let url): return PortalCheck(state: .portal, url: url, hintMinutes: hint(in: google.body))
            case .failed: return PortalCheck(state: .offline)
            }
        }
    }

    private static func fetch(_ endpoint: Endpoint, timeout: TimeInterval) async -> (answer: Answer, body: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout + 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A proxy would answer for the check page itself; the check is about this network.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        // The ordinary user agent, not macOS's own: some sign-in pages answer its sheet differently from a browser.
        let request = URLRequest(url: endpoint.url)
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { return (.failed, "") }
            let body = String(decoding: data.prefix(65_536), as: UTF8.self)
            return (classify(endpoint, status: http.statusCode, body: body, location: http.value(forHTTPHeaderField: "Location")), body)
        } catch { return (.failed, "") }
    }
}

/// Stops at the first answer, so a redirect's Location is the sign-in page rather than followed.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

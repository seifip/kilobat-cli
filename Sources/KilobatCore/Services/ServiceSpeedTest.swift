import Foundation

/// Test this service: one download of at most 25 MB from a public file the service means to be downloaded, only when the
/// person asks, never on a metered network. One connection, like the passive measure, so the two compare.
public enum ServiceSpeedTest {
    public enum Refusal: Error, Equatable, LocalizedError {
        case metered, budget
        public var errorDescription: String? {
            switch self {
            case .metered: String(localized: "This network is metered, so Kilobat won’t download a test file here. Mark it unmetered in Settings › Network if it isn’t.", comment: "Service speed test refused on a metered network")
            case .budget: String(localized: "A service test downloads 5 to 25 MB.", comment: "Service speed test refused: the data budget is out of range")
            }
        }
    }

    /// Throws `Refusal.metered` on a metered network and `Refusal.budget` outside 5–25 MB; nothing is sent then.
    public static func check(metered: Bool, bytes: Int) throws {
        if metered { throw Refusal.metered }
        guard (5_000_000...ServiceSpeedTarget.maximumBytes).contains(bytes) else { throw Refusal.budget }
    }

    /// The request for the first `bytes` of the target's file.
    public static func request(_ target: ServiceSpeedTarget, bytes: Int) -> URLRequest {
        var url = target.url
        if target.sized, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "bytes", value: String(bytes))]
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        if !target.sized { request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Kilobat (service speed test; https://kilobat.app)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Downloads up to `bytes` for up to 10 seconds and returns the transfer, timed from the first byte. Throws a
    /// refusal before sending anything when `metered`.
    public static func run(_ target: ServiceSpeedTarget, metered: Bool, bytes: Int = ServiceSpeedTarget.maximumBytes) async throws -> ServiceTransfer {
        try check(metered: metered, bytes: bytes)
        let started = Date()
        let result = try await Download(cap: bytes, deadline: 10).run(request(target, bytes: bytes))
        guard (200..<300).contains(result.status) else {
            throw DiagnosticError(String(localized: "\(target.name)’s test file answered HTTP \(result.status). Try again later.", comment: "Service speed test failed: a service and an HTTP status code"))
        }
        let received = result.bytes, seconds = max(0.001, result.seconds)
        guard received >= 1_000_000 else { throw DiagnosticError(String(localized: "\(target.name) sent too little to measure. Try again later.", comment: "Service speed test failed: too few bytes")) }
        let address = result.host
        return ServiceTransfer(date: started, seconds: seconds, bytes: UInt64(received), mbps: Double(received) * 8 / seconds / 1_000_000,
                               host: address, app: "Kilobat", tested: true)
    }

    /// One capped download: counts bytes as they arrive and stops at the cap or the deadline, timed from the first byte.
    private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        struct Result { let bytes: Int; let seconds: Double; let status: Int; let host: String? }
        private let lock = NSLock()
        private let cap: Int, deadline: TimeInterval
        private var bytes = 0, status = 0, first: Date?, last: Date?, host: String?, started = Date()
        private var continuation: CheckedContinuation<Result, Error>?
        private var finished = false
        init(cap: Int, deadline: TimeInterval) { self.cap = cap; self.deadline = deadline }

        func run(_ request: URLRequest) async throws -> Result {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = deadline + 10
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: request)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { self.continuation = continuation; started = Date() }
                    task.resume()
                }
            } onCancel: { task.cancel() }
        }
        private func finish(_ outcome: Swift.Result<Result, Error>) {
            let waiting: CheckedContinuation<Result, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true; defer { continuation = nil }; return continuation
            }
            waiting?.resume(with: outcome)
        }
        private var result: Result {
            lock.withLock { Result(bytes: bytes, seconds: (last ?? Date()).timeIntervalSince(first ?? started), status: status, host: host) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            lock.withLock { status = (response as? HTTPURLResponse)?.statusCode ?? 0; host = response.url?.host }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let done: Bool = lock.withLock {
                let now = Date()
                if first == nil { first = now }
                bytes += data.count; last = now
                return bytes >= cap || now.timeIntervalSince(started) >= deadline
            }
            if done { dataTask.cancel(); finish(.success(result)) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, (error as? URLError)?.code != .cancelled { finish(.failure(error)) } else { finish(.success(result)) }
        }
    }
}

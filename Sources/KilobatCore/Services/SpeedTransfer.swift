import Foundation

/// One serial transfer stream. Delegate callbacks report actual transport progress.
final class SpeedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var bytes = 0
    private var status = 0
    private var upload = false
    private var update: (@Sendable (Int) -> Void)?
    private var session: URLSession!
    private var task: URLSessionTask?
    private var cancelled = false
    private var ray: String?
    /// The Cloudflare data center that answered, from the `cf-ray` header's suffix ("8a1b…-FRA").
    var dataCenter: String? { lock.withLock { ray }.flatMap(SpeedTest.dataCenter) }

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func close() { lock.withLock { cancelled = true }; session.invalidateAndCancel() }
    /// Tasks are created under the lock that cancellation takes, so none can start on an invalidated session.
    func cancel() { lock.withLock { cancelled = true; return task }?.cancel() }
    func request(_ request: URLRequest, body: Data?, update: @escaping @Sendable (Int) -> Void) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionTask? = lock.withLock {
                    guard !cancelled else { return nil }
                    self.continuation = continuation; bytes = 0; status = 0
                    upload = body != nil; self.update = update
                    task = body.map { session.uploadTask(with: request, from: $0) } ?? session.dataTask(with: request)
                    return task
                }
                guard let task else { return continuation.resume(throwing: CancellationError()) }
                task.resume()
            }
        } onCancel: { cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            if ray == nil { ray = http?.value(forHTTPHeaderField: "cf-ray") }
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let progress: (Int, (@Sendable (Int) -> Void)?) = lock.withLock {
            if !upload { bytes += data.count }
            return (bytes, upload ? nil : update)
        }
        progress.1?(progress.0)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let callback = lock.withLock { bytes = Int(totalBytesSent); return update }
        callback?(Int(totalBytesSent))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = lock.withLock { () -> (CheckedContinuation<Int, Error>?, Int, Int) in
            let result = (continuation, bytes, status)
            continuation = nil; update = nil; if self.task === task { self.task = nil }
            return result
        }
        if let error { result.0?.resume(throwing: error) }
        else if !(200..<300).contains(result.2) { result.0?.resume(throwing: DiagnosticError(String(localized: "The test server returned HTTP \(result.2). Try again."))) }
        else { result.0?.resume(returning: result.1) }
    }
}

final class SpeedSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var lastBytes = 0
    private var previous = 0.0
    let start = Date()
    func sample(bytes: Int) -> Double? {
        lock.withLock {
            let now = Date(), elapsed = now.timeIntervalSince(last)
            guard elapsed >= 0.15 else { return nil }
            let rate = Double(max(0, bytes - lastBytes)) * 8 / elapsed / 1_000_000
            previous = previous == 0 ? rate : previous * 0.35 + rate * 0.65
            last = now; lastBytes = bytes
            return previous
        }
    }
}

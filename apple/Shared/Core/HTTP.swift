import Foundation

/// URLSession wrapper that pins self-signed server certificates by SHA-256
/// (like SSH known_hosts) and falls back to normal validation otherwise.
final class HTTP: NSObject, URLSessionDelegate, @unchecked Sendable {
    let base: URL
    let fingerprint: String?
    var bearer: String?
    private(set) var seenFingerprint: String?
    private var session: URLSession!

    /// acceptAny: used once when adding a server, to read its fingerprint for the user to confirm.
    init(base: URL, fingerprint: String?, bearer: String? = nil, acceptAny: Bool = false) {
        self.base = base
        self.fingerprint = fingerprint
        self.bearer = bearer
        self.acceptAny = acceptAny
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    private let acceptAny: Bool

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.handle(challenge, pin: fingerprint, acceptAny: acceptAny, seen: { self.seenFingerprint = $0 }, completion: completionHandler)
    }

    static func handle(_ challenge: URLAuthenticationChallenge, pin: String?, acceptAny: Bool, seen: (String) -> Void,
                       completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first
        else { return completion(.performDefaultHandling, nil) }
        let fp = certFingerprint(SecCertificateCopyData(leaf) as Data)
        seen(fp)
        if acceptAny { return completion(.useCredential, URLCredential(trust: trust)) }
        if let pin {
            return normalizedFingerprint(pin) == normalizedFingerprint(fp)
                ? completion(.useCredential, URLCredential(trust: trust))
                : completion(.cancelAuthenticationChallenge, nil)
        }
        completion(.performDefaultHandling, nil)
    }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // keep "+" and friends literal-safe in query values
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], json: Any? = nil,
                 body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url(path, query))
        r.httpMethod = method
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            r.httpBody = body
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func wrap(_ e: Error) -> FSError {
        if let f = e as? FSError { return f }
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled where fingerprint != nil && seenFingerprint != nil
                && normalizedFingerprint(seenFingerprint!) != normalizedFingerprint(fingerprint!):
                return FSError(status: 0, code: "cert_changed",
                               message: "服务器证书与之前信任的不一致，可能存在中间人攻击。若服务器确实更换了证书，请删除该服务器后重新添加。")
            case NSURLErrorTimedOut: return FSError(status: 0, code: "timeout", message: "连接超时")
            case NSURLErrorCancelled: return FSError(status: 0, code: "canceled", message: "已取消")
            case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed:
                return FSError(status: 0, code: "tls", message: "安全连接失败")
            default: return FSError(status: 0, code: "network", message: "无法连接服务器")
            }
        }
        return FSError(status: 0, code: "network", message: e.localizedDescription)
    }

    static func error(status: Int, data: Data) -> FSError {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = j["error"] as? [String: Any] {
            return FSError(status: status, code: e["code"] as? String ?? "error", message: e["message"] as? String ?? "HTTP \(status)")
        }
        return FSError(status: status, code: "http", message: "HTTP \(status)")
    }

    /// Sends a request and returns (status, body); throws only on transport errors.
    func raw(_ r: URLRequest) async throws -> (Int, Data) {
        do {
            let (data, resp) = try await session.data(for: r)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch { throw wrap(error) }
    }

    @discardableResult
    func json(_ r: URLRequest) async throws -> [String: Any] {
        let (status, data) = try await raw(r)
        if status >= 400 { throw Self.error(status: status, data: data) }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func decode<T: Decodable>(_ type: T.Type, _ r: URLRequest) async throws -> T {
        let (status, data) = try await raw(r)
        if status >= 400 { throw Self.error(status: status, data: data) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw FSError(status: 0, code: "decode", message: "无法解析服务器响应") }
    }

    /// Server-Sent Events, one JSON object per data line.
    func events(_ r: URLRequest) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = r
                    req.timeoutInterval = 90
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, resp) = try await session.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 { throw FSError(status: status, code: "events", message: status == 401 ? "授权已失效" : "事件流错误") }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                        cont.yield(j)
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error is FSError ? error : wrap(error))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams a GET into a file (appending when resuming with Range), reporting progress.
    func download(_ r: URLRequest, to file: URL, append: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int {
        let sink = StreamSink(file: file, append: append, progress: progress, pin: fingerprint, acceptAny: acceptAny)
        let s = URLSession(configuration: .ephemeral, delegate: sink, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                sink.continuation = c
                let t = s.dataTask(with: r)
                sink.task = t
                t.resume()
            }
        } onCancel: { sink.task?.cancel() }
    }

    /// Uploads a body, reporting bytes sent.
    func upload(_ r: URLRequest, data: Data, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Int, Data) {
        let tracker = UploadTracker(progress: progress)
        do {
            let (body, resp) = try await session.upload(for: r, from: data, delegate: tracker)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, body)
        } catch { throw wrap(error) }
    }
}

private final class UploadTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (@Sendable (Int64) -> Void)?
    init(progress: (@Sendable (Int64) -> Void)?) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent)
    }
}

private final class StreamSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: URL
    let append: Bool
    let progress: @Sendable (Int64) -> Void
    let pin: String?
    let acceptAny: Bool
    var continuation: CheckedContinuation<Int, Error>?
    var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var status = 0
    private var written: Int64 = 0

    init(file: URL, append: Bool, progress: @escaping @Sendable (Int64) -> Void, pin: String?, acceptAny: Bool) {
        self.file = file; self.append = append; self.progress = progress; self.pin = pin; self.acceptAny = acceptAny
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        HTTP.handle(challenge, pin: pin, acceptAny: acceptAny, seen: { _ in }, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else { return completionHandler(.allow) }
        let fm = FileManager.default
        if !(status == 206 && append) || !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        written += Int64(data.count)
        progress(written)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: status)
        }
        continuation = nil
    }
}

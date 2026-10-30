import Foundation

/// Each request owns its delegate/session. Responses are bounded while receiving, including
/// chunked responses; uploadTask reads the verified staging file without building an httpBody.
final class URLSessionTransport: ObjectTransport {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        guard let host = request.headers.first(where: { $0.key.caseInsensitiveCompare("Host") == .orderedSame })?.value,
              ["GET", "HEAD", "PUT", "POST"].contains(request.method),
              request.responseLimit > 0,
              request.responseLimit <= (request.responseFileURL == nil ? 32 * 1024 * 1024 : Int(V1Validator.maxResourceBytes)),
              request.responseFileURL == nil || (request.method == "GET" && request.responseFileURL!.isFileURL),
              request.bodyFileURL == nil || (request.body.isEmpty && request.method == "PUT") else {
            throw CosFailure(.configuration)
        }
        let path = COSEncoding.encode(request.path, preserveSlash: true)
        let query = request.query.keys.sorted().map { key in
            "\(COSEncoding.encode(key))=\(COSEncoding.encode(request.query[key] ?? ""))"
        }.joined(separator: "&")
        let urlText = "https://\(host)\(path)" + (query.isEmpty ? "" : "?\(query)")
        guard let url = URL(string: urlText), url.scheme == "https", url.host == host else {
            throw CosFailure(.configuration)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        if request.bodyFileURL == nil { urlRequest.httpBody = request.body.isEmpty ? nil : request.body }
        for (name, value) in request.headers where name.caseInsensitiveCompare("Host") != .orderedSame {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let file = request.bodyFileURL {
            guard file.isFileURL,
                  let expected = request.headers.first(where: { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame })?.value,
                  let length = Int64(expected), (1...V1Validator.maxResourceBytes).contains(length),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == length else { throw CosFailure(.contentMismatch) }
        }
        // A large upload must not inherit the former 25-second synchronous deadline.
        let resourceTimeout: TimeInterval = request.bodyFileURL == nil && request.responseFileURL == nil ? 60 : 3600
        let settings = configuration.copy() as! URLSessionConfiguration
        settings.timeoutIntervalForRequest = request.bodyFileURL == nil ? 20 : 120
        settings.timeoutIntervalForResource = resourceTimeout
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        let receiver = BoundedObjectReceiver(limit: request.responseLimit, isHead: request.method == "HEAD", fileURL: request.responseFileURL)
        let session = URLSession(configuration: settings, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task: URLSessionTask
        if let file = request.bodyFileURL {
            task = session.uploadTask(with: urlRequest, fromFile: file)
        } else {
            task = session.dataTask(with: urlRequest)
        }
        task.resume()
        if receiver.completed.wait(timeout: .now() + resourceTimeout + 5) == .timedOut {
            task.cancel()
            throw CosFailure(.timeout)
        }
        return try receiver.result()
    }
}

private final class BoundedObjectReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let limit: Int
    private let isHead: Bool
    private let lock = NSLock()
    private var outcome: Result<ObjectResponse, Error>?
    // Only accessed from the session's serial delegate queue.
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private let fileURL: URL?
    private var file: FileHandle?
    private var received = 0
    private var successBody = false

    init(limit: Int, isHead: Bool, fileURL: URL?) {
        self.limit = limit
        self.isHead = isHead
        self.fileURL = fileURL
    }
    deinit { try? file?.close() }

    func result() throws -> ObjectResponse {
        lock.lock()
        let value = outcome
        lock.unlock()
        return try (value ?? .failure(CosFailure(.network))).get()
    }

    private func finish(_ value: Result<ObjectResponse, Error>) {
        lock.lock()
        let first = outcome == nil
        if first { outcome = value }
        lock.unlock()
        if first { completed.signal() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(CosFailure(.network)))
            completionHandler(.cancel)
            return
        }
        // HEAD's Content-Length describes the remote object, not an incoming body.
        successBody = (200...299).contains(http.statusCode)
        let bodyLimit = fileURL != nil && !successBody ? min(limit, 64 * 1024) : limit
        guard isHead || http.expectedContentLength <= Int64(bodyLimit) else {
            finish(.failure(CosFailure(.contentMismatch)))
            completionHandler(.cancel)
            return
        }
        self.response = http
        if let fileURL, successBody {
            do {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw CosFailure(.contentMismatch) }
                file = try FileHandle(forWritingTo: fileURL)
            } catch {
                finish(.failure(error)); completionHandler(.cancel); return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let bodyLimit = fileURL != nil && !successBody ? min(limit, 64 * 1024) : limit
        guard data.count <= bodyLimit - received else {
            finish(.failure(CosFailure(.contentMismatch)))
            dataTask.cancel()
            return
        }
        received += data.count
        if let file {
            do { try file.write(contentsOf: data) }
            catch { finish(.failure(error)); dataTask.cancel() }
        } else { bytes.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let file {
            do { try file.synchronize(); try file.close(); self.file = nil }
            catch { finish(.failure(error)); return }
        }
        if let error {
            let failure: ConnectionFailure = (error as? URLError)?.code == .timedOut ? .timeout : .network
            finish(.failure(CosFailure(failure)))
        } else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let name = key as? String { headers[name] = String(describing: value) }
            }
            finish(.success(ObjectResponse(status: response.statusCode, headers: headers, body: bytes)))
        } else {
            finish(.failure(CosFailure(.network)))
        }
    }

    // Never forward credentials/signatures to another endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

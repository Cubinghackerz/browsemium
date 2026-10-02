import Darwin
import Foundation

public protocol UserFilterListFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public enum UserFilterListInput {
    public static let maximumBytes = 4 * 1024 * 1024

    public enum InputError: Error, LocalizedError, Equatable {
        case httpsRequired, redirectRefused, tooLarge, invalidEncoding, unreadableFile, fetchFailed
        case httpStatus(Int)
        public var errorDescription: String? {
            switch self {
            case .httpsRequired: "Use an HTTPS address without an embedded username or password."
            case .redirectRefused: "The source redirected to an unsupported address or too many times. Choose a direct HTTPS address."
            case .tooLarge: "The filter list exceeds the 4 MiB input limit. Choose a smaller list."
            case .invalidEncoding: "Choose a UTF-8 filter list. This source uses another encoding."
            case .unreadableFile: "The selected file could not be read. Choose a regular text file, not a folder or symbolic link."
            case .fetchFailed: "The filter list could not be downloaded. Check the address and connection, then try again."
            case .httpStatus(let code): "The source returned HTTP \(code). Choose another address or try again later."
            }
        }
    }

    /// Hold an actual regular-file descriptor, not a size check followed by a
    /// path reopen. A changed file cannot evade the streaming byte ceiling.
    public static func readFile(_ url: URL, maximumBytes: Int = maximumBytes) throws -> Data {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw InputError.unreadableFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InputError.unreadableFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw InputError.unreadableFile
        }
        let limit = min(max(1, maximumBytes), Self.maximumBytes)
        guard metadata.st_size <= limit else { throw InputError.tooLarge }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= limit - data.count else { throw InputError.tooLarge }
                data.append(chunk)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as InputError { throw error }
        catch { throw InputError.unreadableFile }
        guard String(data: data, encoding: .utf8) != nil else { throw InputError.invalidEncoding }
        return data
    }
}

enum UserFilterListRequestPolicy {
    static func request(_ url: URL) throws -> URLRequest {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 4096 else {
            throw UserFilterListInput.InputError.httpsRequired
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("text/plain, application/octet-stream;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    static func redirect(to url: URL, count: Int) throws -> URLRequest {
        guard count <= 5, let request = try? request(url) else { throw UserFilterListInput.InputError.redirectRefused }
        return request // Rebuild instead of forwarding Cookie/Authorization headers.
    }
}

public struct HTTPSUserFilterListFetcher: UserFilterListFetching {
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumBytes: Int

    public init() {
        sessionConfiguration = Self.configuration()
        maximumBytes = UserFilterListInput.maximumBytes
    }

    /// Generated fixtures inject URLProtocol only; production security settings
    /// cannot be weakened by an injected session configuration.
    init(protocolClasses: [AnyClass], maximumBytes: Int) {
        sessionConfiguration = Self.configuration()
        sessionConfiguration.protocolClasses = protocolClasses
        self.maximumBytes = min(max(1, maximumBytes), UserFilterListInput.maximumBytes)
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func fetch(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let request = try UserFilterListRequestPolicy.request(url)
        let download = BoundedFilterListDownload(configuration: sessionConfiguration, maximumBytes: maximumBytes)
        let data = try await withTaskCancellationHandler {
            try await download.start(request)
        } onCancel: { download.cancel() }
        try Task.checkCancellation()
        return data
    }
}

/// Every mutable field is protected by the lock, including cancellation before
/// start. Delegate callbacks retain at most the ceiling and resume exactly once.
private final class BoundedFilterListDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var session: URLSession?
    private var bytes = Data()
    private var redirects = 0
    private var receivedResponse = false

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
    }

    func start(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            lock.unlock()
            task.resume()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        bytes = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(UserFilterListInput.InputError.fetchFailed)); completionHandler(.cancel); return
        }
        guard let url = response.url, (try? UserFilterListRequestPolicy.request(url)) != nil else {
            finish(.failure(UserFilterListInput.InputError.redirectRefused)); completionHandler(.cancel); return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(.failure(UserFilterListInput.InputError.httpStatus(http.statusCode))); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= maximumBytes else {
            finish(.failure(UserFilterListInput.InputError.tooLarge)); completionHandler(.cancel); return
        }
        if let charset = response.textEncodingName?.lowercased(), !["utf-8", "utf8", "us-ascii"].contains(charset) {
            finish(.failure(UserFilterListInput.InputError.invalidEncoding)); completionHandler(.cancel); return
        }
        lock.lock()
        let isFinished = result != nil
        if !isFinished { receivedResponse = true }
        lock.unlock()
        completionHandler(isFinished ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard data.count <= maximumBytes - bytes.count else {
            lock.unlock(); finish(.failure(UserFilterListInput.InputError.tooLarge)); return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = bytes
        let hasResponse = receivedResponse
        lock.unlock()
        if error != nil || !hasResponse { finish(.failure(UserFilterListInput.InputError.fetchFailed)) }
        else if String(data: data, encoding: .utf8) == nil { finish(.failure(UserFilterListInput.InputError.invalidEncoding)) }
        else { finish(.success(data)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        do {
            guard let url = request.url else { throw UserFilterListInput.InputError.redirectRefused }
            completionHandler(try UserFilterListRequestPolicy.redirect(to: url, count: count))
        } catch {
            finish(.failure(UserFilterListInput.InputError.redirectRefused))
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Default system certificate validation only; no password/client-key
        // lookups or user authentication prompts for a filter-list source.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

/// One scope per language-model session; no task-local/global "current channel".
public enum UsageObservedURLSession {
    static let header = "x-sloppy-usage-observation"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var scopes: [String: WeakScope] = [:]
    private final class WeakScope { weak var value: Scope?; init(_ value: Scope) { self.value = value } }

    fileprivate final class Scope: @unchecked Sendable {
        let base: URLSession
        let context: ModelUsageContext
        let decoder: UsageWireDecoder
        init(base: URLSession, context: ModelUsageContext) {
            self.base = base; self.context = context; self.decoder = UsageWireDecoder(context: context)
        }
    }

    public static func make(wrapping base: URLSession?, context: ModelUsageContext) -> URLSession {
        let base = base ?? URLSession(configuration: .default)
        let scope = Scope(base: base, context: context)
        let id = UUID().uuidString
        lock.withLock {
            scopes = scopes.filter { $0.value.value != nil }
            scopes[id] = WeakScope(scope)
        }
        let config = base.configuration
        config.protocolClasses = [UsageObservationURLProtocol.self] + (config.protocolClasses ?? [])
        var headers = config.httpAdditionalHeaders ?? [:]
        headers.removeValue(forKey: TokenUsageCaptureRegistry.headerField)
        headers[header] = id
        config.httpAdditionalHeaders = headers
        return URLSession(configuration: config, delegate: ScopeAnchor(scope: scope), delegateQueue: nil)
    }

    fileprivate static func scope(_ request: URLRequest) -> Scope? {
        guard let id = request.value(forHTTPHeaderField: header) else { return nil }
        return lock.withLock { scopes[id]?.value }
    }

    private final class ScopeAnchor: NSObject, URLSessionDelegate, @unchecked Sendable {
        let scope: Scope
        init(scope: Scope) { self.scope = scope }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            #if canImport(FoundationNetworking)
            completionHandler(.performDefaultHandling, nil)
            #else
            if let delegate = scope.base.delegate, delegate.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))) {
                delegate.urlSession?(session, didReceive: challenge, completionHandler: completionHandler)
            } else { completionHandler(.performDefaultHandling, nil) }
            #endif
        }
    }
}

private final class UsageObservationURLProtocol: URLProtocol {
    private var activeTask: URLSessionDataTask?
    private var activeSession: URLSession?
    private var bridge: Bridge?
    override class func canInit(with request: URLRequest) -> Bool {
        request.httpMethod == "POST" && UsageObservedURLSession.scope(request) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let scope = UsageObservedURLSession.scope(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        var outgoing = request
        let body: Data?
        do {
            var payload = try Self.requestBody(outgoing)
            if let original = payload, outgoing.url?.path.hasSuffix("/chat/completions") == true,
               ["api.openai.com", "openrouter.ai"].contains(outgoing.url?.host ?? ""),
               var object = try? JSONSerialization.jsonObject(with: original) as? [String: Any], object["stream"] as? Bool == true {
                var options = object["stream_options"] as? [String: Any] ?? [:]
                options["include_usage"] = true
                object["stream_options"] = options
                payload = try JSONSerialization.data(withJSONObject: object)
                outgoing.setValue(nil, forHTTPHeaderField: "Content-Length")
            }
            body = payload
            if body != nil { outgoing.httpBodyStream = nil; outgoing.httpBody = body }
        } catch { client?.urlProtocol(self, didFailWithError: error); return }
        outgoing.setValue(nil, forHTTPHeaderField: UsageObservedURLSession.header)
        outgoing.setValue(nil, forHTTPHeaderField: TokenUsageCaptureRegistry.headerField)
        let config = scope.base.configuration
        var forwardingHeaders = config.httpAdditionalHeaders ?? [:]
        forwardingHeaders.removeValue(forKey: TokenUsageCaptureRegistry.headerField)
        config.httpAdditionalHeaders = forwardingHeaders
        // Preserve proxy, custom auth/rewriting protocols and trust handling.
        config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != UsageObservationURLProtocol.self }
        let delegate = Bridge(owner: self, scope: scope, body: body)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        bridge = delegate; activeSession = session
        activeTask = session.dataTask(with: outgoing)
        activeTask?.resume()
    }
    private static func requestBody(_ request: URLRequest) throws -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return result }
            guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    override func stopLoading() { activeTask?.cancel() }
    fileprivate func finish(_ error: Error?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        activeSession?.finishTasksAndInvalidate()
        activeTask = nil; bridge = nil; activeSession = nil
    }

    private final class Bridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: UsageObservationURLProtocol?
        let scope: UsageObservedURLSession.Scope
        let body: Data?
        let id = UUID().uuidString
        let date = Date()
        var buffer = Data()
        var truncated = false
        var statusCode = 0
        init(owner: UsageObservationURLProtocol, scope: UsageObservedURLSession.Scope, body: Data?) {
            self.owner = owner; self.scope = scope; self.body = body
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let owner { owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed) }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let remaining = max(0, 32 * 1024 * 1024 - buffer.count)
            buffer.append(data.prefix(remaining))
            if data.count > remaining { truncated = true }
            if let owner { owner.client?.urlProtocol(owner, didLoad: data) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Await durable accounting before delivering completion to the model/tool loop.
            let response = buffer
            let incomplete = truncated
            let failed = error != nil || statusCode >= 400
            Task { [self] in
                let record = await scope.decoder.record(requestId: id, body: body, response: response,
                    createdAt: date, failed: failed, truncated: incomplete)
                await scope.context.onRequest(record)
                owner?.finish(error)
            }
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            #if canImport(FoundationNetworking)
            completionHandler(.performDefaultHandling, nil)
            #else
            if let delegate = scope.base.delegate, delegate.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))) {
                delegate.urlSession?(session, didReceive: challenge, completionHandler: completionHandler)
            } else { completionHandler(.performDefaultHandling, nil) }
            #endif
        }
    }
}

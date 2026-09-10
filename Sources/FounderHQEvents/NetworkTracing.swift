import Foundation
import ObjectiveC.runtime

/**
 The header the ingest API reads to join a backend event to the visit that
 caused it. Same literal as `FOUNDERHQ_SESSION_ID_HEADER` in
 `@founderhq/events-core`; keep the two in step.
 */
public let FounderHQSessionIdHeader = "x-founderhq-session-id"

/**
 Adds the session header to the app's own API calls. It swizzles the four
 `URLSession` task factories that take a `URLRequest`, in the same one-shot
 style as the screen swizzle, and rewrites the request before the task exists.

 Only the session id travels. A distinct id in a header is forgeable and the
 ingest API ignores it, so sending one would buy nothing and leak a user
 identifier to every listed host.
 */
enum FounderHQNetworkTracing {
    private static let lock = NSLock()
    private static weak var client: FounderHQEvents?
    private static var hostnames: Set<String> = []
    private static var installed = false
    private static var debug = false

    static func install(
        client: FounderHQEvents,
        hostnames: [String],
        ingestHostname: String?,
        debug: Bool
    ) {
        var allowed = Set<String>()
        for entry in hostnames {
            guard let hostname = normalizedHostname(entry) else {
                founderHQDebugLog(debug) {
                    "tracingHeaders ignored \"\(entry)\": it must be a bare hostname"
                }
                continue
            }
            allowed.insert(hostname)
        }
        // Our own ingest already carries the session id in the event body, and
        // the header would only duplicate it.
        if let ingest = ingestHostname?.lowercased() { allowed.remove(ingest) }

        lock.lock()
        Self.client = client
        Self.hostnames = allowed
        Self.debug = debug
        let shouldSwizzle = !installed && !allowed.isEmpty
        if shouldSwizzle { installed = true }
        lock.unlock()

        guard shouldSwizzle else { return }
        exchange("dataTaskWithRequest:", "fhq_dataTaskWithRequest:", debug: debug)
        exchange(
            "dataTaskWithRequest:completionHandler:",
            "fhq_dataTaskWithRequest:completionHandler:",
            debug: debug
        )
        exchange(
            "uploadTaskWithRequest:fromData:",
            "fhq_uploadTaskWithRequest:fromData:",
            debug: debug
        )
        exchange("downloadTaskWithRequest:", "fhq_downloadTaskWithRequest:", debug: debug)
    }

    /** Returns the request with the header added, or the request untouched. */
    static func decorate(_ request: URLRequest) -> URLRequest {
        lock.lock()
        let allowed = hostnames
        let client = Self.client
        let debug = Self.debug
        lock.unlock()
        guard !allowed.isEmpty,
              let hostname = request.url?.host?.lowercased(),
              allowed.contains(hostname),
              request.value(forHTTPHeaderField: FounderHQSessionIdHeader) == nil,
              let sessionId = client?.currentTracingSessionId()
        else { return request }
        var tagged = request
        tagged.setValue(sessionId, forHTTPHeaderField: FounderHQSessionIdHeader)
        founderHQDebugLog(debug) { "tagged a request to \(hostname) with the session id" }
        return tagged
    }

    private static func exchange(_ original: String, _ replacement: String, debug: Bool) {
        guard let originalMethod = class_getInstanceMethod(
            URLSession.self,
            NSSelectorFromString(original)
        ), let replacementMethod = class_getInstanceMethod(
            URLSession.self,
            NSSelectorFromString(replacement)
        ) else {
            founderHQDebugLog(debug) { "tracingHeaders could not hook \(original)" }
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /** Rejects anything that is not a bare hostname: no scheme, path, or port. */
    private static func normalizedHostname(_ value: String) -> String? {
        let hostname = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !hostname.isEmpty,
              !hostname.contains("/"),
              !hostname.contains(":"),
              !hostname.contains("*"),
              !hostname.contains("?"),
              !hostname.contains("@")
        else { return nil }
        return hostname
    }
}

private extension URLSession {
    @objc(fhq_dataTaskWithRequest:)
    func fhq_dataTask(with request: URLRequest) -> URLSessionDataTask {
        fhq_dataTask(with: FounderHQNetworkTracing.decorate(request))
    }

    @objc(fhq_dataTaskWithRequest:completionHandler:)
    func fhq_dataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        fhq_dataTask(
            with: FounderHQNetworkTracing.decorate(request),
            completionHandler: completionHandler
        )
    }

    @objc(fhq_uploadTaskWithRequest:fromData:)
    func fhq_uploadTask(with request: URLRequest, from data: Data?) -> URLSessionUploadTask {
        fhq_uploadTask(with: FounderHQNetworkTracing.decorate(request), from: data)
    }

    @objc(fhq_downloadTaskWithRequest:)
    func fhq_downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        fhq_downloadTask(with: FounderHQNetworkTracing.decorate(request))
    }
}

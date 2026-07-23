import Foundation
import SwipeFlowCore

struct PlaybackNetworkProbeResult: Sendable {
    let route: [PlaybackRouteStep]
    let status: String
    let responseTime: TimeInterval
    let contentType: String?
    let contentLength: Int64?
    let acceptsByteRanges: Bool?
}

enum PlaybackNetworkProbe {
    static func run(for url: URL, timeout: TimeInterval = 12) async -> PlaybackNetworkProbeResult {
        let recorder = PlaybackRedirectRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false

        let session = URLSession(
            configuration: configuration,
            delegate: recorder,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let startedAt = Date()

        do {
            let (_, response) = try await session.bytes(for: request)
            let elapsed = Date().timeIntervalSince(startedAt)
            guard let httpResponse = response as? HTTPURLResponse else {
                return PlaybackNetworkProbeResult(
                    route: recorder.steps,
                    status: "收到的不是 HTTP 响应",
                    responseTime: elapsed,
                    contentType: response.mimeType,
                    contentLength: response.expectedContentLength >= 0
                        ? response.expectedContentLength
                        : nil,
                    acceptsByteRanges: nil
                )
            }

            var route = recorder.steps
            if let finalURL = httpResponse.url {
                route.append(
                    PlaybackRouteStep(
                        label: "网络检测最终响应（HTTP \(httpResponse.statusCode)）",
                        redactedAddress: PlaybackAddressRedactor.redactedAddress(for: finalURL)
                    )
                )
            }
            let acceptsRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
                .map { $0.lowercased() != "none" }
            return PlaybackNetworkProbeResult(
                route: route,
                status: "HTTP \(httpResponse.statusCode)",
                responseTime: elapsed,
                contentType: httpResponse.mimeType,
                contentLength: httpResponse.expectedContentLength >= 0
                    ? httpResponse.expectedContentLength
                    : nil,
                acceptsByteRanges: acceptsRanges
            )
        } catch let error as URLError {
            let description = switch error.code {
            case .timedOut: "网络检测超时"
            case .cannotFindHost: "找不到媒体服务器"
            case .cannotConnectToHost: "无法连接媒体服务器"
            case .networkConnectionLost: "连接中断"
            case .notConnectedToInternet: "网络未连接"
            case .secureConnectionFailed: "HTTPS 连接失败"
            default: "网络检测失败（\(error.errorCode)）"
            }
            return PlaybackNetworkProbeResult(
                route: recorder.steps,
                status: description,
                responseTime: Date().timeIntervalSince(startedAt),
                contentType: nil,
                contentLength: nil,
                acceptsByteRanges: nil
            )
        } catch {
            return PlaybackNetworkProbeResult(
                route: recorder.steps,
                status: "网络检测失败",
                responseTime: Date().timeIntervalSince(startedAt),
                contentType: nil,
                contentLength: nil,
                acceptsByteRanges: nil
            )
        }
    }
}

private final class PlaybackRedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [PlaybackRouteStep] = []

    var steps: [PlaybackRouteStep] {
        lock.withLock { recordedSteps }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let redirectURL = request.url {
            lock.withLock {
                recordedSteps.append(
                    PlaybackRouteStep(
                        label: "网络检测跳转（HTTP \(response.statusCode)）",
                        redactedAddress: PlaybackAddressRedactor.redactedAddress(for: redirectURL)
                    )
                )
            }
        }
        completionHandler(request)
    }
}

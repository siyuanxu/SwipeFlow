import Foundation
import SwipeFlowCore

public struct VidpickCredentials: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct VidpickReviewSnapshot: Sendable {
    public let retention: [MediaItemID: RetentionState]
    public let favorites: Set<MediaItemID>

    public init(
        retention: [MediaItemID: RetentionState],
        favorites: Set<MediaItemID>
    ) {
        self.retention = retention
        self.favorites = favorites
    }
}

public struct VidpickConfiguration: Sendable {
    public let id: MediaSourceID
    public let displayName: String
    public let baseURL: URL
    public let folderPath: String
    public let recursive: Bool

    public init(
        id: MediaSourceID,
        displayName: String,
        baseURL: URL,
        folderPath: String = "/",
        recursive: Bool = true
    ) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw VidpickConnectorError.invalidServerURL
        }
        guard folderPath.hasPrefix("/"),
              !folderPath.split(separator: "/").contains("..") else {
            throw VidpickConnectorError.invalidFolderPath
        }

        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.folderPath = folderPath
        self.recursive = recursive
    }
}

public enum VidpickConnectorError: Error, Equatable, LocalizedError, Sendable {
    case invalidServerURL
    case invalidFolderPath
    case authenticationFailed
    case requestFailed(statusCode: Int)
    case invalidResponse
    case itemNotFound
    case invalidPlaybackRedirect
    case deletionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Vidpick 地址必须是没有内嵌账号、查询参数或片段的 HTTPS 地址。"
        case .invalidFolderPath:
            "Vidpick 媒体目录必须是以 / 开头的有效路径。"
        case .authenticationFailed:
            "Vidpick 登录失败，请检查用户名和密码。"
        case let .requestFailed(statusCode):
            "Vidpick 请求失败（HTTP \(statusCode)）。"
        case .invalidResponse:
            "Vidpick 返回了无法识别的数据。"
        case .itemNotFound:
            "Vidpick 播放列表中没有这个视频。"
        case .invalidPlaybackRedirect:
            "Vidpick 没有返回安全的 HTTPS 播放地址。"
        case let .deletionFailed(message):
            "Vidpick 删除失败：\(message)"
        }
    }
}

public struct VidpickSource: MediaSource {
    public typealias CredentialProvider = @Sendable () async throws -> VidpickCredentials

    public let descriptor: MediaSourceDescriptor

    private let client: VidpickClient

    public init(
        configuration: VidpickConfiguration,
        session: URLSession = VidpickSource.makeEphemeralSession(),
        credentials: @escaping CredentialProvider
    ) {
        descriptor = MediaSourceDescriptor(
            id: configuration.id,
            displayName: configuration.displayName,
            capabilities: [
                .browse,
                .playback,
                .favorite,
                .retention,
                .stagedDeletion,
                .permanentDeletion,
            ]
        )
        client = VidpickClient(
            configuration: configuration,
            session: session,
            credentials: credentials
        )
    }

    public func fetchPage(_ request: MediaPageRequest) async throws -> MediaPage {
        try await client.fetchPage(request)
    }

    public func resolvePlayback(for itemID: MediaItemID) async throws -> PlaybackResource {
        try await client.resolvePlayback(for: itemID)
    }

    public func fetchReviewSnapshot() async throws -> VidpickReviewSnapshot {
        try await client.fetchReviewSnapshot()
    }

    public func perform(_ action: MediaAction, on itemID: MediaItemID) async throws {
        try await client.perform(action, itemIDs: [itemID])
    }

    public func perform(_ action: MediaAction, on itemIDs: [MediaItemID]) async throws {
        try await client.perform(action, itemIDs: itemIDs)
    }

    public static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }
}

private struct VidpickScanRequest: Encodable {
    let action = "scan"
    let path: String
    let recursive: Bool
}

private struct VidpickScanResponse: Decodable {
    let videos: [VidpickVideo]
}

private struct VidpickVideo: Decodable, Sendable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let modified: String
}

private struct VidpickStatePayload: Codable, Sendable {
    var version: Int
    var decisions: [String: String]
    var likes: [String: String]
    var activeSession: JSONValue?
}

private indirect enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

private struct VidpickDeleteRequest: Encodable {
    let action = "delete"
    let root: String
    let paths: [String]
}

private struct VidpickDeleteResponse: Decodable {
    let results: [VidpickDeleteResult]
}

private struct VidpickDeleteResult: Decodable {
    let path: String
    let ok: Bool
    let message: String?
}

private actor VidpickClient {
    private let configuration: VidpickConfiguration
    private let session: URLSession
    private let credentials: VidpickSource.CredentialProvider
    private var videos: [VidpickVideo]?
    private var synchronizedState: VidpickStatePayload?

    init(
        configuration: VidpickConfiguration,
        session: URLSession,
        credentials: @escaping VidpickSource.CredentialProvider
    ) {
        self.configuration = configuration
        self.session = session
        self.credentials = credentials
    }

    func fetchPage(_ pageRequest: MediaPageRequest) async throws -> MediaPage {
        let videos = try await loadedVideos()
        let offset = pageRequest.cursor.flatMap(Int.init) ?? 0
        guard offset >= 0, offset <= videos.count else {
            throw VidpickConnectorError.invalidResponse
        }
        let end = min(offset + pageRequest.pageSize, videos.count)
        let page = videos[offset..<end].map { video in
            MediaItem(
                reference: MediaReference(
                    sourceID: configuration.id,
                    itemID: MediaItemID(rawValue: video.path)
                ),
                title: video.name,
                detailText: Self.detailText(for: video),
                kind: .video,
                fileExtension: URL(fileURLWithPath: video.path).pathExtension.lowercased()
            )
        }
        let nextCursor = end < videos.count ? String(end) : nil
        return MediaPage(items: page, nextCursor: nextCursor)
    }

    func resolvePlayback(for itemID: MediaItemID) async throws -> PlaybackResource {
        let videos = try await loadedVideos()
        guard videos.contains(where: { $0.path == itemID.rawValue }) else {
            throw VidpickConnectorError.itemNotFound
        }

        var components = URLComponents(
            url: endpoint("api/media"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: itemID.rawValue)]
        guard let url = components?.url else {
            throw VidpickConnectorError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await authorize(&request)

        let (_, response) = try await session.data(
            for: request,
            delegate: VidpickRedirectBlocker.shared
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VidpickConnectorError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode, allowing: 302...399)
        guard let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let resolvedURL = URL(string: location, relativeTo: url)?.absoluteURL,
              resolvedURL.scheme?.lowercased() == "https",
              resolvedURL.host != nil,
              resolvedURL.user == nil,
              resolvedURL.password == nil else {
            throw VidpickConnectorError.invalidPlaybackRedirect
        }
        return PlaybackResource(
            url: resolvedURL,
            diagnosticRoute: [
                PlaybackRouteStep(
                    label: "Vidpick 播放接口",
                    redactedAddress: PlaybackAddressRedactor.redactedAddress(for: url)
                ),
                PlaybackRouteStep(
                    label: "Vidpick 返回地址（HTTP \(httpResponse.statusCode)）",
                    redactedAddress: PlaybackAddressRedactor.redactedAddress(for: resolvedURL)
                ),
            ]
        )
    }

    func fetchReviewSnapshot() async throws -> VidpickReviewSnapshot {
        let state = try await loadedState()
        let retention = state.decisions.reduce(into: [MediaItemID: RetentionState]()) {
            partial, entry in
            switch entry.value {
            case "keep":
                partial[MediaItemID(rawValue: entry.key)] = .keep
            case "delete":
                partial[MediaItemID(rawValue: entry.key)] = .reviewForDeletion
            default:
                break
            }
        }
        let favorites = Set(
            state.likes.compactMap { entry in
                entry.value == "favorite" ? MediaItemID(rawValue: entry.key) : nil
            }
        )
        return VidpickReviewSnapshot(retention: retention, favorites: favorites)
    }

    func perform(_ action: MediaAction, itemIDs: [MediaItemID]) async throws {
        guard !itemIDs.isEmpty else { return }
        let knownPaths = Set(try await loadedVideos().map(\.path))
        let paths = itemIDs.map(\.rawValue)
        guard paths.allSatisfy({ knownPaths.contains($0) }) else {
            throw VidpickConnectorError.itemNotFound
        }

        if action == .deletePermanently {
            let state = try? await loadedState()
            try await delete(paths: paths)
            videos?.removeAll { paths.contains($0.path) }
            if var state {
                for path in paths {
                    state.decisions.removeValue(forKey: path)
                    state.likes.removeValue(forKey: path)
                }
                // The files are already deleted at this point. A broken optional
                // state endpoint must not make the client report the deletion as
                // failed or leave successfully deleted items in the local queue.
                try? await saveState(state)
            }
            return
        }

        var state = try await loadedState()
        for path in paths {
            switch action {
            case let .setFavorite(isFavorite):
                if isFavorite {
                    state.likes[path] = "favorite"
                } else {
                    state.likes.removeValue(forKey: path)
                }
            case let .setRetention(retention):
                switch retention {
                case .undecided:
                    state.decisions.removeValue(forKey: path)
                case .keep:
                    state.decisions[path] = "keep"
                case .reviewForDeletion:
                    state.decisions[path] = "delete"
                }
            case .stageDeletion:
                state.decisions[path] = "delete"
            case .restoreFromStagedDeletion:
                state.decisions[path] = "keep"
            case .deletePermanently:
                break
            }
        }
        try await saveState(state)
    }

    private func loadedVideos() async throws -> [VidpickVideo] {
        if let videos {
            return videos
        }

        var request = URLRequest(url: endpoint("api/openlist"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            VidpickScanRequest(
                path: configuration.folderPath,
                recursive: configuration.recursive
            )
        )
        try await authorize(&request)

        let (data, response) = try await session.data(
            for: request,
            delegate: VidpickRedirectBlocker.shared
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VidpickConnectorError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode)
        guard let payload = try? JSONDecoder().decode(VidpickScanResponse.self, from: data),
              payload.videos.allSatisfy({ $0.path.hasPrefix("/") }) else {
            throw VidpickConnectorError.invalidResponse
        }
        videos = payload.videos
        return payload.videos
    }

    private func loadedState() async throws -> VidpickStatePayload {
        if let synchronizedState {
            return synchronizedState
        }
        var request = URLRequest(url: endpoint("api/state"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VidpickConnectorError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode)
        guard let state = try? JSONDecoder().decode(VidpickStatePayload.self, from: data) else {
            throw VidpickConnectorError.invalidResponse
        }
        synchronizedState = state
        return state
    }

    private func saveState(_ state: VidpickStatePayload) async throws {
        var request = URLRequest(url: endpoint("api/state"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(state)
        try await authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VidpickConnectorError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode)
        guard let saved = try? JSONDecoder().decode(VidpickStatePayload.self, from: data) else {
            throw VidpickConnectorError.invalidResponse
        }
        synchronizedState = saved
    }

    private func delete(paths: [String]) async throws {
        var request = URLRequest(url: endpoint("api/openlist"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            VidpickDeleteRequest(root: configuration.folderPath, paths: paths)
        )
        try await authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VidpickConnectorError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode)
        guard let payload = try? JSONDecoder().decode(VidpickDeleteResponse.self, from: data),
              payload.results.count == paths.count else {
            throw VidpickConnectorError.invalidResponse
        }
        let failures = payload.results.filter { !$0.ok }
        guard failures.isEmpty else {
            let message = failures.prefix(3).map { failure in
                failure.message.map { "\(failure.path)：\($0)" } ?? failure.path
            }.joined(separator: "；")
            throw VidpickConnectorError.deletionFailed(message)
        }
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let credentials = try await credentials()
        let value = Data("\(credentials.username):\(credentials.password)".utf8)
            .base64EncodedString()
        request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
    }

    private func validateStatus(
        _ statusCode: Int,
        allowing range: ClosedRange<Int> = 200...299
    ) throws {
        if statusCode == 401 {
            throw VidpickConnectorError.authenticationFailed
        }
        guard range.contains(statusCode) else {
            throw VidpickConnectorError.requestFailed(statusCode: statusCode)
        }
    }

    private func endpoint(_ relativePath: String) -> URL {
        var base = configuration.baseURL.absoluteString
        if !base.hasSuffix("/") {
            base.append("/")
        }
        return URL(string: relativePath, relativeTo: URL(string: base))!.absoluteURL
    }

    private static func detailText(for video: VidpickVideo) -> String? {
        guard video.size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file)
    }
}

private final class VidpickRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = VidpickRedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

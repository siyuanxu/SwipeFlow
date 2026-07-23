import Foundation

public struct MediaSourceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MediaItemID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MediaReference: Hashable, Codable, Sendable {
    public let sourceID: MediaSourceID
    public let itemID: MediaItemID

    public init(sourceID: MediaSourceID, itemID: MediaItemID) {
        self.sourceID = sourceID
        self.itemID = itemID
    }
}

public struct MediaSourceCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let browse = Self(rawValue: 1 << 0)
    public static let playback = Self(rawValue: 1 << 1)
    public static let favorite = Self(rawValue: 1 << 2)
    public static let retention = Self(rawValue: 1 << 3)
    public static let stagedDeletion = Self(rawValue: 1 << 4)
    public static let permanentDeletion = Self(rawValue: 1 << 5)
}

public struct MediaSourceDescriptor: Hashable, Codable, Sendable {
    public let id: MediaSourceID
    public let displayName: String
    public let capabilities: MediaSourceCapabilities

    public init(
        id: MediaSourceID,
        displayName: String,
        capabilities: MediaSourceCapabilities
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public enum MediaKind: String, Codable, Sendable {
    case video
    case streamReference
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public var id: MediaReference { reference }

    public let reference: MediaReference
    public let title: String
    public let detailText: String?
    public let kind: MediaKind
    public let fileExtension: String?

    public init(
        reference: MediaReference,
        title: String,
        detailText: String? = nil,
        kind: MediaKind,
        fileExtension: String? = nil
    ) {
        self.reference = reference
        self.title = title
        self.detailText = detailText
        self.kind = kind
        self.fileExtension = fileExtension
    }
}

public struct MediaPageRequest: Hashable, Codable, Sendable {
    public let cursor: String?
    public let pageSize: Int

    public init(cursor: String? = nil, pageSize: Int = 50) {
        self.cursor = cursor
        self.pageSize = min(max(pageSize, 1), 200)
    }
}

public struct MediaPage: Hashable, Codable, Sendable {
    public let items: [MediaItem]
    public let nextCursor: String?

    public init(items: [MediaItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A short-lived playback result. Callers must not persist or log this value because
/// a remote URL or header may contain temporary authorization material.
public struct PlaybackRouteStep: Hashable, Sendable {
    public let label: String
    public let redactedAddress: String

    public init(label: String, redactedAddress: String) {
        self.label = label
        self.redactedAddress = redactedAddress
    }
}

public struct PlaybackResource: Sendable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let expiresAt: Date?
    /// Display-only routing information. Values must have credentials, query values,
    /// fragments, cookies and signatures removed before entering this model.
    public let diagnosticRoute: [PlaybackRouteStep]

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        expiresAt: Date? = nil,
        diagnosticRoute: [PlaybackRouteStep] = []
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.expiresAt = expiresAt
        self.diagnosticRoute = diagnosticRoute
    }
}

public enum RetentionState: String, Codable, Sendable {
    case undecided
    case keep
    case reviewForDeletion
}

public enum MediaAction: Hashable, Codable, Sendable {
    case setFavorite(Bool)
    case setRetention(RetentionState)
    case stageDeletion
    case restoreFromStagedDeletion
    case deletePermanently
}

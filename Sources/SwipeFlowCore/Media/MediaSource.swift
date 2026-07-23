import Foundation

public protocol MediaSource: Sendable {
    var descriptor: MediaSourceDescriptor { get }

    func fetchPage(_ request: MediaPageRequest) async throws -> MediaPage
    func resolvePlayback(for itemID: MediaItemID) async throws -> PlaybackResource
    func perform(_ action: MediaAction, on itemID: MediaItemID) async throws
    func perform(_ action: MediaAction, on itemIDs: [MediaItemID]) async throws
}

public extension MediaSource {
    func perform(_ action: MediaAction, on itemID: MediaItemID) async throws {
        throw MediaSourceError.unsupportedAction
    }

    func perform(_ action: MediaAction, on itemIDs: [MediaItemID]) async throws {
        for itemID in itemIDs {
            try await perform(action, on: itemID)
        }
    }
}

public enum MediaSourceError: Error, Equatable, LocalizedError, Sendable {
    case duplicateSource(MediaSourceID)
    case sourceNotFound(MediaSourceID)
    case itemSourceMismatch
    case unsupportedAction

    public var errorDescription: String? {
        switch self {
        case .duplicateSource:
            "A media source with the same identifier is already registered."
        case .sourceNotFound:
            "The requested media source is not registered."
        case .itemSourceMismatch:
            "The media item belongs to a different source."
        case .unsupportedAction:
            "This media source does not support the requested action."
        }
    }
}

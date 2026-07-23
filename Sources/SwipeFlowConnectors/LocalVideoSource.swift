import Foundation
import SwipeFlowCore

public struct LocalVideoSource: MediaSource {
    public static let supportedExtensions: Set<String> = [
        "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4",
        "mpeg", "mpg", "ts", "webm", "wmv"
    ]

    public let descriptor: MediaSourceDescriptor
    private let rootURL: URL

    public init(
        id: MediaSourceID,
        displayName: String,
        rootURL: URL
    ) throws {
        self.rootURL = try DirectoryIndex.validateRoot(rootURL)
        self.descriptor = MediaSourceDescriptor(
            id: id,
            displayName: displayName,
            capabilities: [.browse, .playback]
        )
    }

    public func fetchPage(_ request: MediaPageRequest) async throws -> MediaPage {
        let files = try DirectoryIndex.files(
            in: rootURL,
            extensions: Self.supportedExtensions
        )
        return try DirectoryIndex.page(
            files: files,
            sourceID: descriptor.id,
            kind: .video,
            request: request
        )
    }

    public func resolvePlayback(for itemID: MediaItemID) async throws -> PlaybackResource {
        let fileURL = try DirectoryIndex.file(for: itemID, beneath: rootURL)
        guard Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            throw DirectoryConnectorError.itemNotFound
        }
        return PlaybackResource(
            url: fileURL,
            diagnosticRoute: [
                PlaybackRouteStep(
                    label: "本地文件",
                    redactedAddress: PlaybackAddressRedactor.redactedAddress(for: fileURL)
                )
            ]
        )
    }
}

import Foundation
import SwipeFlowCore

public struct STRMFolderSource: MediaSource {
    private static let maximumFileSize = 64 * 1024

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
        let files = try DirectoryIndex.files(in: rootURL, extensions: ["strm"])
        return try DirectoryIndex.page(
            files: files,
            sourceID: descriptor.id,
            kind: .streamReference,
            request: request
        )
    }

    public func resolvePlayback(for itemID: MediaItemID) async throws -> PlaybackResource {
        let fileURL = try DirectoryIndex.file(for: itemID, beneath: rootURL)
        guard fileURL.pathExtension.lowercased() == "strm" else {
            throw DirectoryConnectorError.itemNotFound
        }

        let data = try readLimitedData(from: fileURL)
        guard var contents = String(data: data, encoding: .utf8) else {
            throw DirectoryConnectorError.malformedStreamReference
        }
        if contents.hasPrefix("\u{feff}") {
            contents.removeFirst()
        }

        guard let line = contents
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
            throw DirectoryConnectorError.malformedStreamReference
        }

        let playbackURL = try parsePlaybackURL(line, relativeTo: fileURL)
        return PlaybackResource(
            url: playbackURL,
            diagnosticRoute: [
                PlaybackRouteStep(
                    label: "STRM 指向地址",
                    redactedAddress: PlaybackAddressRedactor.redactedAddress(for: playbackURL)
                )
            ]
        )
    }

    private func readLimitedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
        guard data.count <= Self.maximumFileSize else {
            throw DirectoryConnectorError.streamReferenceTooLarge
        }
        return data
    }

    private func parsePlaybackURL(_ value: String, relativeTo strmURL: URL) throws -> URL {
        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else if let parsed = URL(string: value), parsed.scheme != nil {
            url = parsed
        } else {
            url = strmURL.deletingLastPathComponent()
                .appendingPathComponent(value)
                .standardizedFileURL
        }

        guard let scheme = url.scheme?.lowercased(), ["file", "http", "https"].contains(scheme) else {
            throw DirectoryConnectorError.unsupportedStreamScheme
        }
        guard url.user == nil, url.password == nil else {
            throw DirectoryConnectorError.embeddedCredentialsNotAllowed
        }
        return url
    }
}

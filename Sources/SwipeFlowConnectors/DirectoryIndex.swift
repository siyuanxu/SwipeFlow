import Foundation
import SwipeFlowCore

enum DirectoryConnectorError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot
    case invalidCursor
    case itemOutsideRoot
    case itemNotFound
    case unreadableDirectory
    case malformedStreamReference
    case unsupportedStreamScheme
    case embeddedCredentialsNotAllowed
    case streamReferenceTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "The selected source is not a local directory."
        case .invalidCursor:
            "The media page cursor is invalid."
        case .itemOutsideRoot:
            "The requested item is outside the selected directory."
        case .itemNotFound:
            "The requested media item no longer exists."
        case .unreadableDirectory:
            "The selected directory could not be read."
        case .malformedStreamReference:
            "The .strm file does not contain a valid playback location."
        case .unsupportedStreamScheme:
            "The .strm file uses an unsupported URL scheme."
        case .embeddedCredentialsNotAllowed:
            "Credentials embedded in a .strm URL are not allowed."
        case .streamReferenceTooLarge:
            "The .strm file is unexpectedly large."
        }
    }
}

struct IndexedFile: Sendable {
    let url: URL
    let relativePath: String
}

enum DirectoryIndex {
    static func validateRoot(_ rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard root.isFileURL,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DirectoryConnectorError.invalidRoot
        }
        return root
    }

    static func files(in root: URL, extensions: Set<String>) throws -> [IndexedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw DirectoryConnectorError.unreadableDirectory
        }

        var results: [IndexedFile] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  extensions.contains(fileURL.pathExtension.lowercased()),
                  let relativePath = relativePath(for: fileURL, beneath: root) else {
                continue
            }
            results.append(IndexedFile(url: fileURL, relativePath: relativePath))
        }

        if enumerationError != nil {
            throw DirectoryConnectorError.unreadableDirectory
        }

        return results.sorted {
            $0.relativePath.compare(
                $1.relativePath,
                options: [.caseInsensitive, .numeric]
            ) == .orderedAscending
        }
    }

    static func page(
        files: [IndexedFile],
        sourceID: MediaSourceID,
        kind: MediaKind,
        request: MediaPageRequest
    ) throws -> MediaPage {
        let offset: Int
        if let cursor = request.cursor {
            guard let value = Int(cursor), value >= 0, value <= files.count else {
                throw DirectoryConnectorError.invalidCursor
            }
            offset = value
        } else {
            offset = 0
        }

        let end = min(offset + request.pageSize, files.count)
        let items = files[offset..<end].map { file in
            MediaItem(
                reference: MediaReference(
                    sourceID: sourceID,
                    itemID: MediaItemID(rawValue: file.relativePath)
                ),
                title: file.url.deletingPathExtension().lastPathComponent,
                detailText: parentPath(of: file.relativePath),
                kind: kind,
                fileExtension: file.url.pathExtension.lowercased()
            )
        }
        return MediaPage(
            items: Array(items),
            nextCursor: end < files.count ? String(end) : nil
        )
    }

    static func file(for itemID: MediaItemID, beneath root: URL) throws -> URL {
        let itemPath = itemID.rawValue
        guard !itemPath.isEmpty,
              !itemPath.hasPrefix("/"),
              !itemPath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw DirectoryConnectorError.itemOutsideRoot
        }

        let candidate = root.appendingPathComponent(itemPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard relativePath(for: candidate, beneath: root) != nil else {
            throw DirectoryConnectorError.itemOutsideRoot
        }

        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw DirectoryConnectorError.itemNotFound
        }
        return candidate
    }

    private static func relativePath(for file: URL, beneath root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func parentPath(of relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }
}

import Foundation
import XCTest
import SwipeFlowCore
@testable import SwipeFlowConnectors

private func withTemporaryDirectory(
    _ operation: (URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwipeFlowTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try await operation(url)
}

final class DirectorySourceTests: XCTestCase {
    func testLocalVideoSourceFiltersAndPaginatesFiles() async throws {
        try await withTemporaryDirectory { root in
            try Data().write(to: root.appendingPathComponent("01.mp4"))
            try Data().write(to: root.appendingPathComponent("02.mkv"))
            try Data().write(to: root.appendingPathComponent("notes.txt"))

            let source = try LocalVideoSource(
                id: MediaSourceID(rawValue: "local"),
                displayName: "Local",
                rootURL: root
            )
            let first = try await source.fetchPage(MediaPageRequest(pageSize: 1))
            let second = try await source.fetchPage(
                MediaPageRequest(cursor: first.nextCursor, pageSize: 1)
            )

            XCTAssertEqual(first.items.map(\.title), ["01"])
            XCTAssertEqual(first.nextCursor, "1")
            XCTAssertEqual(second.items.map(\.title), ["02"])
            XCTAssertNil(second.nextCursor)
        }
    }

    func testLocalVideoSourceRejectsTraversalIdentifiers() async throws {
        try await withTemporaryDirectory { root in
            let source = try LocalVideoSource(
                id: MediaSourceID(rawValue: "local"),
                displayName: "Local",
                rootURL: root
            )

            do {
                _ = try await source.resolvePlayback(
                    for: MediaItemID(rawValue: "../outside.mp4")
                )
                XCTFail("Expected traversal identifier to be rejected")
            } catch let error as DirectoryConnectorError {
                XCTAssertEqual(error, .itemOutsideRoot)
            }
        }
    }

    func testSTRMSourceResolvesHTTPSWithoutPersistingItInTheItem() async throws {
        try await withTemporaryDirectory { root in
            let strm = root.appendingPathComponent("sample.strm")
            try Data("# comment\nhttps://media.example.invalid/video.mp4\n".utf8).write(to: strm)

            let source = try STRMFolderSource(
                id: MediaSourceID(rawValue: "strm"),
                displayName: "STRM",
                rootURL: root
            )
            let page = try await source.fetchPage(MediaPageRequest())
            let item = try XCTUnwrap(page.items.first)
            let resource = try await source.resolvePlayback(for: item.reference.itemID)

            XCTAssertEqual(item.reference.itemID.rawValue, "sample.strm")
            XCTAssertEqual(resource.url.host, "media.example.invalid")
        }
    }

    func testSTRMSourceRejectsUnsupportedSchemesAndEmbeddedCredentials() async throws {
        try await withTemporaryDirectory { root in
            let source = try STRMFolderSource(
                id: MediaSourceID(rawValue: "strm"),
                displayName: "STRM",
                rootURL: root
            )

            let unsupported = root.appendingPathComponent("unsupported.strm")
            try Data("ftp://media.example.invalid/video.mp4".utf8).write(to: unsupported)
            do {
                _ = try await source.resolvePlayback(
                    for: MediaItemID(rawValue: "unsupported.strm")
                )
                XCTFail("Expected unsupported scheme to be rejected")
            } catch let error as DirectoryConnectorError {
                XCTAssertEqual(error, .unsupportedStreamScheme)
        }

        let credentialed = root.appendingPathComponent("credentialed.strm")
        var components = URLComponents()
        components.scheme = "https"
        components.user = "example-user"
        components.password = "example-secret"
        components.host = "media.example.invalid"
        components.path = "/video.mp4"
        let credentialedValue = try XCTUnwrap(components.string)
        try Data(credentialedValue.utf8).write(to: credentialed)
            do {
                _ = try await source.resolvePlayback(
                    for: MediaItemID(rawValue: "credentialed.strm")
                )
                XCTFail("Expected embedded credentials to be rejected")
            } catch let error as DirectoryConnectorError {
                XCTAssertEqual(error, .embeddedCredentialsNotAllowed)
            }
        }
    }
}

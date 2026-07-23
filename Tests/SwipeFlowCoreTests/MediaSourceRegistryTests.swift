import Foundation
import XCTest
@testable import SwipeFlowCore

private struct StubSource: MediaSource {
    let descriptor = MediaSourceDescriptor(
        id: MediaSourceID(rawValue: "stub"),
        displayName: "Stub",
        capabilities: [.browse, .playback]
    )

    func fetchPage(_ request: MediaPageRequest) async throws -> MediaPage {
        MediaPage(items: [])
    }

    func resolvePlayback(for itemID: MediaItemID) async throws -> PlaybackResource {
        PlaybackResource(url: URL(fileURLWithPath: "/tmp/example.mp4"))
    }
}

@MainActor
private final class StubPlaybackEngine: PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    func load(_ resource: PlaybackResource) async throws {
        state = .paused(position: 0)
    }

    func play() {
        state = .playing(position: 0)
    }

    func pause() {
        state = .paused(position: 0)
    }

    func seek(to position: TimeInterval) {
        state = .paused(position: position)
    }

    func unload() {
        state = .idle
    }
}

final class MediaSourceRegistryTests: XCTestCase {
    func testRegistryRoutesPlaybackBySourceIdentifier() async throws {
        let registry = MediaSourceRegistry()
        try await registry.register(StubSource())

        let resource = try await registry.resolvePlayback(
            for: MediaReference(
                sourceID: MediaSourceID(rawValue: "stub"),
                itemID: MediaItemID(rawValue: "example")
            )
        )

        XCTAssertEqual(resource.url.lastPathComponent, "example.mp4")
    }

    func testRegistryRejectsDuplicateSources() async throws {
        let registry = MediaSourceRegistry()
        try await registry.register(StubSource())

        do {
            try await registry.register(StubSource())
            XCTFail("Expected duplicate source registration to fail")
        } catch let error as MediaSourceError {
            XCTAssertEqual(
                error,
                .duplicateSource(MediaSourceID(rawValue: "stub"))
            )
        }
    }

    func testPageSizeIsBounded() {
        XCTAssertEqual(MediaPageRequest(pageSize: 0).pageSize, 1)
        XCTAssertEqual(MediaPageRequest(pageSize: 1_000).pageSize, 200)
    }

    func testPlaybackAddressRedactorHidesCredentialsQueryAndFragment() throws {
        let url = try XCTUnwrap(
            URL(string: "https://user:password@media.example.invalid/video.mp4?sign=secret#fragment")
        )
        let redacted = PlaybackAddressRedactor.redactedAddress(for: url)

        XCTAssertEqual(
            redacted,
            "https://media.example.invalid/video.mp4?<查询参数已隐藏>"
        )
        XCTAssertFalse(redacted.contains("password"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("fragment"))
    }

    func testPlaybackWindowKeepsPreviousCurrentAndFiveUpcomingItems() {
        let policy = PlaybackWindowPolicy()

        XCTAssertEqual(policy.indexes(focusedIndex: 2, itemCount: 10), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(
            policy.loadingOrder(focusedIndex: 2, itemCount: 10),
            [2, 3, 4, 5, 6, 7, 1]
        )
        XCTAssertEqual(policy.indexes(focusedIndex: 0, itemCount: 2), [0, 1])
    }

    @MainActor
    func testPlaybackPoolExposesPreparedEngineForRendering() async {
        let sourceID = MediaSourceID(rawValue: "pool-test")
        let items = (0..<3).map { index in
            MediaItem(
                reference: MediaReference(
                    sourceID: sourceID,
                    itemID: MediaItemID(rawValue: "item-\(index)")
                ),
                title: "Item \(index)",
                kind: .video
            )
        }
        var changeCount = 0
        let pool = PlaybackPool(
            buildEngine: { StubPlaybackEngine() },
            didChange: { changeCount += 1 }
        )

        await pool.focus(on: 1, items: items) { _ in
            PlaybackResource(url: URL(fileURLWithPath: "/tmp/example.mp4"))
        }

        XCTAssertNotNil(pool.engine(for: items[1].reference))
        XCTAssertEqual(pool.activeReferences, Set(items.map(\.reference)))
        XCTAssertGreaterThan(changeCount, 0)
    }
}

import Foundation
import SwipeFlowConnectors
import SwipeFlowCore

enum CheckFailure: Error {
    case failed(String)
}

struct SwipeFlowChecks {
    static func run() async throws {
        try await checkLocalVideoSource()
        try await checkSTRMSource()
        try await checkRegistry()
        try await checkPlaybackPool()
        print("SwipeFlow checks passed")
    }

    private static func checkLocalVideoSource() async throws {
        try await withTemporaryDirectory { root in
            try Data().write(to: root.appendingPathComponent("01.mp4"))
            try Data().write(to: root.appendingPathComponent("notes.txt"))

            let source = try LocalVideoSource(
                id: MediaSourceID(rawValue: "check-local"),
                displayName: "Local Check",
                rootURL: root
            )
            let page = try await source.fetchPage(MediaPageRequest())
            try require(page.items.map(\.title) == ["01"], "Local filtering failed")

            do {
                _ = try await source.resolvePlayback(
                    for: MediaItemID(rawValue: "../outside.mp4")
                )
                throw CheckFailure.failed("Traversal protection failed")
            } catch is CheckFailure {
                throw CheckFailure.failed("Traversal protection failed")
            } catch {
                // The connector correctly rejected an identifier outside its root.
            }
        }
    }

    private static func checkSTRMSource() async throws {
        try await withTemporaryDirectory { root in
            let strmURL = root.appendingPathComponent("sample.strm")
            try Data("https://media.example.invalid/video.mp4\n".utf8).write(to: strmURL)

            let source = try STRMFolderSource(
                id: MediaSourceID(rawValue: "check-strm"),
                displayName: "STRM Check",
                rootURL: root
            )
            let page = try await source.fetchPage(MediaPageRequest())
            let item = try require(page.items.first, "STRM item was not indexed")
            let resource = try await source.resolvePlayback(for: item.reference.itemID)
            try require(
                resource.url.host == "media.example.invalid",
                "STRM URL resolution failed"
            )
        }
    }

    private static func checkRegistry() async throws {
        let registry = MediaSourceRegistry()
        try await withTemporaryDirectory { root in
            try Data().write(to: root.appendingPathComponent("video.mp4"))
            let source = try LocalVideoSource(
                id: MediaSourceID(rawValue: "check-registry"),
                displayName: "Registry Check",
                rootURL: root
            )
            try await registry.register(source)
            let page = try await registry.fetchPage(
                from: source.descriptor.id,
                request: MediaPageRequest()
            )
            let reference = try require(page.items.first?.reference, "Registry page was empty")
            let resource = try await registry.resolvePlayback(for: reference)
            try require(resource.url.lastPathComponent == "video.mp4", "Registry routing failed")
        }
    }

    @MainActor
    private static func checkPlaybackPool() async throws {
        var engines: [CheckPlaybackEngine] = []
        let pool = PlaybackPool {
            let engine = CheckPlaybackEngine()
            engines.append(engine)
            return engine
        }
        let sourceID = MediaSourceID(rawValue: "check-pool")
        let items = (0..<10).map { index in
            MediaItem(
                reference: MediaReference(
                    sourceID: sourceID,
                    itemID: MediaItemID(rawValue: "item-\(index)")
                ),
                title: "Item \(index)",
                kind: .video
            )
        }

        await pool.focus(on: 1, items: items) { reference in
            PlaybackResource(
                url: URL(fileURLWithPath: "/tmp/\(reference.itemID.rawValue).mp4")
            )
        }
        try require(
            pool.activeReferences == Set(items[0...6].map(\.reference)),
            "Initial playback window was incorrect"
        )
        try require(engines.count == 7, "Playback pool did not create seven engines")

        await pool.focus(on: 2, items: items) { reference in
            PlaybackResource(
                url: URL(fileURLWithPath: "/tmp/\(reference.itemID.rawValue).mp4")
            )
        }
        try require(
            pool.activeReferences == Set(items[1...7].map(\.reference)),
            "Shifted playback window was incorrect"
        )
        try require(engines.count == 7, "Playback pool did not reuse an engine")
        try require(
            pool.focusedReference == items[2].reference,
            "Playback pool focused the wrong item"
        )
    }

    private static func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwipeFlowChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await operation(url)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw CheckFailure.failed(message) }
        return value
    }
}

@MainActor
private final class CheckPlaybackEngine: PlaybackEngine {
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

try await SwipeFlowChecks.run()

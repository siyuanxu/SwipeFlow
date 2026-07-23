import Foundation

public enum PlaybackPreparationFailure: Equatable, Sendable {
    case resourceResolutionFailed
    case engineCreationFailed
    case engineLoadingFailed
}

/// Maintains reusable engines around the focused feed item.
///
/// `PlaybackResource` values and underlying errors are deliberately not retained:
/// either may contain a signed URL or authorization header.
@MainActor
public final class PlaybackPool {
    public typealias EngineBuilder = @MainActor () throws -> any PlaybackEngine
    public typealias ResourceResolver = (MediaReference) async throws -> PlaybackResource

    public let policy: PlaybackWindowPolicy
    public private(set) var focusedReference: MediaReference?
    public private(set) var failures: [MediaReference: PlaybackPreparationFailure] = [:]

    private let buildEngine: EngineBuilder
    private let didChange: @MainActor () -> Void
    private var activeEngines: [MediaReference: any PlaybackEngine] = [:]
    private var failedEngines: [MediaReference: any PlaybackEngine] = [:]
    private var idleEngines: [any PlaybackEngine] = []
    private var generation = 0

    public init(
        policy: PlaybackWindowPolicy = PlaybackWindowPolicy(),
        buildEngine: @escaping EngineBuilder,
        didChange: @escaping @MainActor () -> Void = {}
    ) {
        self.policy = policy
        self.buildEngine = buildEngine
        self.didChange = didChange
    }

    public var activeReferences: Set<MediaReference> {
        Set(activeEngines.keys)
    }

    public func engine(for reference: MediaReference) -> (any PlaybackEngine)? {
        activeEngines[reference] ?? failedEngines[reference]
    }

    public func focus(
        on focusedIndex: Int,
        items: [MediaItem],
        resolve: @escaping ResourceResolver
    ) async {
        generation &+= 1
        let requestedGeneration = generation
        let indexes = policy.indexes(focusedIndex: focusedIndex, itemCount: items.count)

        guard let focusedItem = items[safe: focusedIndex], !indexes.isEmpty else {
            focusedReference = nil
            recycleAllActiveEngines()
            failures = [:]
            didChange()
            return
        }

        let desiredReferences = Set(indexes.map { items[$0].reference })
        focusedReference = focusedItem.reference
        failures = failures.filter { desiredReferences.contains($0.key) }

        for reference in Array(activeEngines.keys) where !desiredReferences.contains(reference) {
            recycleEngine(for: reference)
        }
        for reference in Array(failedEngines.keys) where !desiredReferences.contains(reference) {
            recycleFailedEngine(for: reference)
        }

        for (reference, engine) in activeEngines {
            if reference == focusedItem.reference {
                engine.play()
            } else {
                engine.pause()
            }
        }

        for index in policy.loadingOrder(focusedIndex: focusedIndex, itemCount: items.count) {
            let reference = items[index].reference
            guard activeEngines[reference] == nil else { continue }

            let resource: PlaybackResource
            do {
                resource = try await resolve(reference)
            } catch {
                guard generation == requestedGeneration else { return }
                failures[reference] = .resourceResolutionFailed
                continue
            }

            guard generation == requestedGeneration else { return }

            let engine: any PlaybackEngine
            if let failed = failedEngines.removeValue(forKey: reference) {
                engine = failed
            } else if let reusable = idleEngines.popLast() {
                engine = reusable
            } else {
                do {
                    engine = try buildEngine()
                } catch {
                    failures[reference] = .engineCreationFailed
                    continue
                }
            }

            do {
                try await engine.load(resource)
            } catch {
                guard generation == requestedGeneration else {
                    engine.unload()
                    idleEngines.append(engine)
                    return
                }
                // Keep the failed engine while it remains in the playback window so
                // its already-sanitized diagnostics are available to the UI.
                failedEngines[reference] = engine
                failures[reference] = .engineLoadingFailed
                didChange()
                continue
            }

            guard generation == requestedGeneration else {
                engine.unload()
                idleEngines.append(engine)
                return
            }

            activeEngines[reference] = engine
            failures[reference] = nil
            didChange()
            if reference == focusedItem.reference {
                engine.play()
            } else {
                engine.pause()
            }
        }

        trimIdleEngines()
    }

    public func unloadAll() {
        generation &+= 1
        focusedReference = nil
        failures = [:]

        for engine in activeEngines.values {
            engine.unload()
        }
        for engine in failedEngines.values {
            engine.unload()
        }
        for engine in idleEngines {
            engine.unload()
        }
        activeEngines = [:]
        failedEngines = [:]
        idleEngines = []
        didChange()
    }

    private func recycleAllActiveEngines() {
        for reference in Array(activeEngines.keys) {
            recycleEngine(for: reference)
        }
        for reference in Array(failedEngines.keys) {
            recycleFailedEngine(for: reference)
        }
        trimIdleEngines()
    }

    private func recycleEngine(for reference: MediaReference) {
        guard let engine = activeEngines.removeValue(forKey: reference) else { return }
        engine.unload()
        idleEngines.append(engine)
        didChange()
    }

    private func recycleFailedEngine(for reference: MediaReference) {
        guard let engine = failedEngines.removeValue(forKey: reference) else { return }
        engine.unload()
        idleEngines.append(engine)
        didChange()
    }

    private func trimIdleEngines() {
        let maximumIdleCount = max(1, policy.capacity)
        while idleEngines.count > maximumIdleCount {
            idleEngines.removeLast().unload()
        }
    }
}

private extension Collection where Index == Int {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

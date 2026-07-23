public actor MediaSourceRegistry {
    private var sources: [MediaSourceID: any MediaSource] = [:]

    public init() {}

    public func register(_ source: any MediaSource) throws {
        let id = source.descriptor.id
        guard sources[id] == nil else {
            throw MediaSourceError.duplicateSource(id)
        }
        sources[id] = source
    }

    public func unregister(id: MediaSourceID) {
        sources[id] = nil
    }

    public func descriptors() -> [MediaSourceDescriptor] {
        sources.values
            .map(\.descriptor)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func fetchPage(
        from sourceID: MediaSourceID,
        request: MediaPageRequest
    ) async throws -> MediaPage {
        let source = try source(for: sourceID)
        return try await source.fetchPage(request)
    }

    public func resolvePlayback(for reference: MediaReference) async throws -> PlaybackResource {
        let source = try source(for: reference.sourceID)
        return try await source.resolvePlayback(for: reference.itemID)
    }

    public func perform(_ action: MediaAction, on reference: MediaReference) async throws {
        let source = try source(for: reference.sourceID)
        try await source.perform(action, on: reference.itemID)
    }

    private func source(for id: MediaSourceID) throws -> any MediaSource {
        guard let source = sources[id] else {
            throw MediaSourceError.sourceNotFound(id)
        }
        return source
    }
}

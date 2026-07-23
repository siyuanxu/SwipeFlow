import Foundation

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case paused(position: TimeInterval)
    case playing(position: TimeInterval)
    case failed(message: String)
}

/// The UI-facing boundary implemented by native playback adapters.
/// Implementations own their rendering surface and all player-thread synchronization.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }

    func load(_ resource: PlaybackResource) async throws
    func play()
    func pause()
    func seek(to position: TimeInterval)
    func unload()
}

import AppKit
import Combine
import CoreAudio
import Foundation
import SwipeFlowCore

@MainActor
public final class MPVPlaybackEngine: ObservableObject, PlaybackEngine {
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var playbackRate: Double = 1
    @Published public private(set) var diagnostics = MPVPlaybackDiagnostics()

    private let client: MPVClient
    private let displayBridge = MPVPlaybackDisplayBridge()
    private let openGLContext: NSOpenGLContext?
    private var renderer: MPVOpenGLRenderer?
    private var lastPosition: TimeInterval = 0
    private var progressTask: Task<Void, Never>?
    private var diagnosticRefreshCounter = 0
    private var loadGeneration = 0
    private let defaultAudioDeviceDidChange: @MainActor @Sendable () -> Void
    private let localLoadTimeout: TimeInterval
    private let remoteLoadTimeout: TimeInterval
    private var audioDeviceListener: DefaultAudioDeviceListener?

    public init(
        configuration: MPVConfiguration = MPVConfiguration(),
        defaultAudioDeviceDidChange: @escaping @MainActor @Sendable () -> Void = {}
    ) throws {
        self.defaultAudioDeviceDidChange = defaultAudioDeviceDidChange
        localLoadTimeout = configuration.localLoadTimeout
        remoteLoadTimeout = configuration.remoteLoadTimeout
        isMuted = configuration.startMuted
        client = try MPVClient(configuration: configuration)

        switch configuration.videoOutput {
        case .renderAPI:
            guard let pixelFormat = makeMPVOpenGLPixelFormat(),
                  let context = NSOpenGLContext(format: pixelFormat, share: nil) else {
                throw MPVIntegrationError.openGLUnavailable
            }
            openGLContext = context
            renderer = try MPVOpenGLRenderer(
                client: client,
                openGLContext: context
            ) { [displayBridge] in
                displayBridge.requestDisplay()
            }
        case .headless:
            openGLContext = nil
            renderer = nil
        }
        installAudioDeviceChangeListener()
    }

    public func load(_ resource: PlaybackResource) async throws {
        guard resource.httpHeaders.isEmpty else {
            throw MPVIntegrationError.httpHeadersNotYetSupported
        }

        loadGeneration &+= 1
        let requestedGeneration = loadGeneration
        diagnostics = MPVPlaybackDiagnostics()
        diagnostics.route = resource.diagnosticRoute.isEmpty
            ? [
                PlaybackRouteStep(
                    label: "播放器输入地址",
                    redactedAddress: PlaybackAddressRedactor.redactedAddress(for: resource.url)
                )
            ]
            : resource.diagnosticRoute
        let loadTimeout = resource.url.isFileURL ? localLoadTimeout : remoteLoadTimeout
        diagnostics.loadTimeout = loadTimeout
        state = .loading
        do {
            try await client.command(["set", "mute", isMuted ? "yes" : "no"])
            try await client.command(["set", "speed", "1"])
            playbackRate = 1
            try await client.command(["set", "pause", "yes"])
            await client.discardPendingEvents()
            try await client.command(["loadfile", playbackLocation(for: resource.url), "replace"])
            try await client.waitUntilFileLoaded(timeout: loadTimeout)
            lastPosition = 0
            position = 0
            duration = max(0, try await client.doubleProperty("duration") ?? 0)
            await refreshPlaybackDiagnostics()
            state = .paused(position: 0)
            startProgressUpdatesIfNeeded()
        } catch {
            let message = sanitizedMessage(for: error)
            diagnostics.errorMessage = message
            await refreshPlaybackDiagnostics(preservingError: message)
            state = .failed(message: message)
            if !resource.url.isFileURL {
                startNetworkProbe(for: resource.url, generation: requestedGeneration)
            }
            throw error
        }
    }

    public func play() {
        schedule(["set", "pause", "no"]) { [weak self] in
            guard let self else { return }
            state = .playing(position: lastPosition)
        }
    }

    public func pause() {
        schedule(["set", "pause", "yes"]) { [weak self] in
            guard let self else { return }
            state = .paused(position: lastPosition)
        }
    }

    public func seek(to position: TimeInterval) {
        let safePosition = max(0, position)
        schedule(["seek", String(safePosition), "absolute+exact"]) { [weak self] in
            guard let self else { return }
            lastPosition = safePosition
            self.position = safePosition
            switch state {
            case .playing:
                state = .playing(position: safePosition)
            default:
                state = .paused(position: safePosition)
            }
        }
    }

    public func setMuted(_ muted: Bool) {
        schedule(["set", "mute", muted ? "yes" : "no"]) { [weak self] in
            self?.isMuted = muted
        }
    }

    public func setPlaybackRate(_ rate: Double) {
        let safeRate = min(max(rate, 0.25), 4)
        schedule(["set", "speed", String(safeRate)]) { [weak self] in
            self?.playbackRate = safeRate
        }
    }

    public func unload() {
        loadGeneration &+= 1
        progressTask?.cancel()
        progressTask = nil
        schedule(["stop"]) { [weak self] in
            guard let self else { return }
            lastPosition = 0
            position = 0
            duration = 0
            playbackRate = 1
            diagnostics = MPVPlaybackDiagnostics()
            state = .idle
        }
    }

    public var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    var openGLContextForRendering: NSOpenGLContext? {
        openGLContext
    }

    func attachRenderingView(_ view: NSView) {
        displayBridge.attach(view)
    }

    func detachRenderingView(_ view: NSView) {
        displayBridge.detach(view)
    }

    func draw(width: Int, height: Int, framebuffer: Int32 = 0) throws {
        try renderer?.draw(width: width, height: height, framebuffer: framebuffer)
    }

    func reportRenderingFailure(_ error: Error) {
        let message = sanitizedMessage(for: error)
        diagnostics.errorMessage = message
        state = .failed(message: message)
    }

    private func startProgressUpdatesIfNeeded() {
        guard renderer != nil else { return }
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshPlaybackMetrics()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refreshPlaybackMetrics() async {
        do {
            if let updatedPosition = try await client.doubleProperty("time-pos") {
                position = max(0, updatedPosition)
                lastPosition = position
                switch state {
                case .playing:
                    state = .playing(position: position)
                case .paused:
                    state = .paused(position: position)
                default:
                    break
                }
            }
            if let updatedDuration = try await client.doubleProperty("duration") {
                duration = max(0, updatedDuration)
            }
            diagnosticRefreshCounter &+= 1
            if diagnosticRefreshCounter.isMultiple(of: 4) {
                await refreshPlaybackDiagnostics()
            }
        } catch {
            // A transient unavailable property must not interrupt playback.
        }
    }

    private func refreshPlaybackDiagnostics(preservingError errorMessage: String? = nil) async {
        let properties = await client.stringProperties([
            "file-format",
            "video-codec",
            "video-format",
            "width",
            "height",
            "estimated-vf-fps",
            "container-fps",
            "video-bitrate",
            "audio-codec-name",
            "audio-bitrate",
            "hwdec-current",
            "demuxer-cache-duration",
            "cache-buffering-state",
            "paused-for-cache",
            "dropped-frames",
            "decoder-frame-drop-count",
            "avsync",
            "stream-open-filename",
        ])

        var updated = diagnostics
        updated.container = nonempty(properties["file-format"])
        updated.videoCodec = nonempty(properties["video-codec"])
        updated.pixelFormat = nonempty(properties["video-format"])
        updated.width = integer(properties["width"])
        updated.height = integer(properties["height"])
        updated.framesPerSecond = number(properties["estimated-vf-fps"])
            ?? number(properties["container-fps"])
        updated.videoBitrate = number(properties["video-bitrate"])
        updated.audioCodec = nonempty(properties["audio-codec-name"])
        updated.audioBitrate = number(properties["audio-bitrate"])
        updated.hardwareDecoder = nonempty(properties["hwdec-current"])
        updated.cacheDuration = number(properties["demuxer-cache-duration"])
        updated.cachePercent = number(properties["cache-buffering-state"])
        updated.pausedForCache = boolean(properties["paused-for-cache"])
        updated.droppedFrames = integer(properties["dropped-frames"])
            ?? integer(properties["decoder-frame-drop-count"])
        updated.audioVideoSync = number(properties["avsync"])
        updated.errorMessage = errorMessage ?? diagnostics.errorMessage

        if let openFilename = nonempty(properties["stream-open-filename"]),
           let url = openFilename.hasPrefix("/")
            ? URL(fileURLWithPath: openFilename)
            : URL(string: openFilename) {
            let step = PlaybackRouteStep(
                label: "libmpv 实际打开地址",
                redactedAddress: PlaybackAddressRedactor.redactedAddress(for: url)
            )
            if updated.route.last != step {
                updated.route.append(step)
            }
        }
        diagnostics = updated
    }

    private func startNetworkProbe(for url: URL, generation: Int) {
        Task { [weak self] in
            let result = await PlaybackNetworkProbe.run(for: url)
            guard let self, loadGeneration == generation else { return }
            var updated = diagnostics
            for step in result.route where !updated.route.contains(step) {
                updated.route.append(step)
            }
            updated.networkProbeStatus = result.status
            updated.networkResponseTime = result.responseTime
            updated.networkContentType = result.contentType
            updated.networkContentLength = result.contentLength
            updated.networkAcceptsByteRanges = result.acceptsByteRanges
            diagnostics = updated
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }

    private func number(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite else { return nil }
        return number
    }

    private func integer(_ value: String?) -> Int? {
        guard let value else { return nil }
        if let integer = Int(value) { return integer }
        guard let number = Double(value), number.isFinite else { return nil }
        return Int(number)
    }

    private func boolean(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }

    private func installAudioDeviceChangeListener() {
        audioDeviceListener = DefaultAudioDeviceListener { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setMuted(true)
                self.defaultAudioDeviceDidChange()
            }
        }
    }

    private func schedule(
        _ arguments: [String],
        onSuccess: @escaping @MainActor () -> Void
    ) {
        Task { [weak self, client] in
            do {
                try await client.command(arguments)
                guard self != nil else { return }
                onSuccess()
            } catch {
                let message = self?.sanitizedMessage(for: error) ?? "Playback failed."
                self?.diagnostics.errorMessage = message
                self?.state = .failed(message: message)
            }
        }
    }

    private func playbackLocation(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    private func sanitizedMessage(for error: Error) -> String {
        if let integrationError = error as? MPVIntegrationError {
            return integrationError.localizedDescription
        }
        return "Playback failed."
    }
}

private final class DefaultAudioDeviceListener: @unchecked Sendable {
    private let listener: AudioObjectPropertyListenerBlock

    init?(onChange: @escaping @Sendable () -> Void) {
        listener = { _, _ in onChange() }
        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        guard status == noErr else { return nil }
    }

    deinit {
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
    }

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

@MainActor
private final class MPVPlaybackDisplayBridge {
    private weak var view: NSView?

    func attach(_ view: NSView) {
        self.view = view
        view.needsDisplay = true
    }

    func detach(_ view: NSView) {
        guard self.view === view else { return }
        self.view = nil
    }

    func requestDisplay() {
        view?.needsDisplay = true
    }
}

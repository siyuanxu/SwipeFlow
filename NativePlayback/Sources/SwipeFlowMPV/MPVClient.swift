import CMPV
import Dispatch
import Foundation

public enum MPVVideoOutput: Hashable, Sendable {
    case renderAPI
    case headless
}

public struct MPVConfiguration: Hashable, Sendable {
    public var videoOutput: MPVVideoOutput
    public var hardwareDecoding: String
    public var cacheSeconds: TimeInterval
    public var cacheByteLimit: Int
    public var startMuted: Bool
    public var localLoadTimeout: TimeInterval
    public var remoteLoadTimeout: TimeInterval

    public init(
        videoOutput: MPVVideoOutput = .renderAPI,
        hardwareDecoding: String = "auto-safe",
        cacheSeconds: TimeInterval = 15,
        cacheByteLimit: Int = 64 * 1_024 * 1_024,
        startMuted: Bool = true,
        localLoadTimeout: TimeInterval = 15,
        remoteLoadTimeout: TimeInterval = 45
    ) {
        self.videoOutput = videoOutput
        self.hardwareDecoding = hardwareDecoding
        self.cacheSeconds = max(0, cacheSeconds)
        self.cacheByteLimit = max(1_024 * 1_024, cacheByteLimit)
        self.startMuted = startMuted
        self.localLoadTimeout = max(5, localLoadTimeout)
        self.remoteLoadTimeout = max(15, remoteLoadTimeout)
    }
}

final class MPVClient: @unchecked Sendable {
    let handle: OpaquePointer

    private let commandQueue = DispatchQueue(label: "app.swipeflow.mpv.commands")
    private let eventQueue = DispatchQueue(label: "app.swipeflow.mpv.events")

    init(configuration: MPVConfiguration) throws {
        try MPVRuntime.validateClientAPI()
        guard let handle = mpv_create() else {
            throw MPVIntegrationError.clientCreationFailed
        }
        self.handle = handle

        do {
            try Self.setOption(handle: handle, name: "config", value: "no")
            try Self.setOption(handle: handle, name: "terminal", value: "no")
            try Self.setOption(handle: handle, name: "input-default-bindings", value: "no")
            try Self.setOption(handle: handle, name: "input-vo-keyboard", value: "no")
            try Self.setOption(handle: handle, name: "sid", value: "no")
            try Self.setOption(handle: handle, name: "secondary-sid", value: "no")
            try Self.setOption(handle: handle, name: "sub-auto", value: "no")
            try Self.setOption(handle: handle, name: "sub-visibility", value: "no")
            try Self.setOption(handle: handle, name: "idle", value: "yes")
            try Self.setOption(
                handle: handle,
                name: "mute",
                value: configuration.startMuted ? "yes" : "no"
            )
            try Self.setOption(
                handle: handle,
                name: "hwdec",
                value: configuration.hardwareDecoding
            )
            if configuration.cacheSeconds > 0 {
                let seconds = String(configuration.cacheSeconds)
                try Self.setOption(handle: handle, name: "cache", value: "yes")
                try Self.setOption(handle: handle, name: "cache-secs", value: seconds)
                try Self.setOption(
                    handle: handle,
                    name: "demuxer-readahead-secs",
                    value: seconds
                )
                try Self.setOption(
                    handle: handle,
                    name: "demuxer-max-bytes",
                    value: String(configuration.cacheByteLimit)
                )
                try Self.setOption(handle: handle, name: "cache-on-disk", value: "no")
            }

            switch configuration.videoOutput {
            case .renderAPI:
                try Self.setOption(handle: handle, name: "vo", value: "libmpv")
            case .headless:
                try Self.setOption(handle: handle, name: "vo", value: "null")
                try Self.setOption(handle: handle, name: "ao", value: "null")
            }

            let result = mpv_initialize(handle)
            guard result >= 0 else {
                throw MPVIntegrationError.initializationFailed(code: result)
            }
        } catch {
            // `self` already owns the handle, so a throwing initializer will run
            // `deinit` and release it exactly once.
            throw error
        }
    }

    deinit {
        commandQueue.sync {
            mpv_terminate_destroy(handle)
        }
    }

    func command(_ arguments: [String]) async throws {
        let handleBits = UInt(bitPattern: handle)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            commandQueue.async {
                do {
                    guard let handle = OpaquePointer(bitPattern: handleBits) else {
                        throw MPVIntegrationError.clientCreationFailed
                    }
                    try Self.runCommand(handle: handle, arguments: arguments)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func doubleProperty(_ name: String) async throws -> Double? {
        let handleBits = UInt(bitPattern: handle)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Double?, Error>) in
            commandQueue.async {
                guard let handle = OpaquePointer(bitPattern: handleBits) else {
                    continuation.resume(throwing: MPVIntegrationError.clientCreationFailed)
                    return
                }
                var value = 0.0
                let result = name.withCString { namePointer in
                    mpv_get_property(handle, namePointer, MPV_FORMAT_DOUBLE, &value)
                }
                if result == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue {
                    continuation.resume(returning: nil)
                } else if result < 0 {
                    continuation.resume(
                        throwing: MPVIntegrationError.propertyReadFailed(
                            name: name,
                            code: result
                        )
                    )
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    func stringProperties(_ names: [String]) async -> [String: String] {
        let handleBits = UInt(bitPattern: handle)
        return await withCheckedContinuation { continuation in
            commandQueue.async {
                guard let handle = OpaquePointer(bitPattern: handleBits) else {
                    continuation.resume(returning: [:])
                    return
                }
                var values: [String: String] = [:]
                for name in names {
                    let value = name.withCString { namePointer in
                        mpv_get_property_string(handle, namePointer)
                    }
                    guard let value else { continue }
                    values[name] = String(cString: value)
                    mpv_free(value)
                }
                continuation.resume(returning: values)
            }
        }
    }

    func discardPendingEvents() async {
        let handleBits = UInt(bitPattern: handle)
        await withCheckedContinuation { continuation in
            eventQueue.async {
                guard let handle = OpaquePointer(bitPattern: handleBits) else {
                    continuation.resume()
                    return
                }
                while mpv_wait_event(handle, 0).pointee.event_id != MPV_EVENT_NONE {
                    // Events never retain playback URLs or headers here.
                }
                continuation.resume()
            }
        }
    }

    func waitUntilFileLoaded(timeout: TimeInterval = 15) async throws {
        let handleBits = UInt(bitPattern: handle)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            eventQueue.async {
                guard let handle = OpaquePointer(bitPattern: handleBits) else {
                    continuation.resume(throwing: MPVIntegrationError.clientCreationFailed)
                    return
                }

                let deadline = Date.timeIntervalSinceReferenceDate + timeout
                var hasSeenStartFile = false
                while Date.timeIntervalSinceReferenceDate < deadline {
                    let remaining = deadline - Date.timeIntervalSinceReferenceDate
                    let event = mpv_wait_event(handle, min(remaining, 0.25)).pointee
                    switch event.event_id {
                    case MPV_EVENT_START_FILE:
                        hasSeenStartFile = true
                    case MPV_EVENT_FILE_LOADED:
                        continuation.resume()
                        return
                    case MPV_EVENT_END_FILE:
                        guard hasSeenStartFile, let eventData = event.data else {
                            continue
                        }
                        let endFile = eventData
                            .assumingMemoryBound(to: mpv_event_end_file.self)
                            .pointee
                        if endFile.reason == MPV_END_FILE_REASON_REDIRECT {
                            hasSeenStartFile = false
                            continue
                        }
                        let errorCode = endFile.error < 0
                            ? endFile.error
                            : Int32(MPV_ERROR_LOADING_FAILED.rawValue)
                        continuation.resume(
                            throwing: MPVIntegrationError.mediaLoadFailed(code: errorCode)
                        )
                        return
                    case MPV_EVENT_SHUTDOWN:
                        continuation.resume(throwing: MPVIntegrationError.clientCreationFailed)
                        return
                    default:
                        continue
                    }
                }
                continuation.resume(
                    throwing: MPVIntegrationError.mediaLoadTimedOut(
                        seconds: Int(timeout.rounded())
                    )
                )
            }
        }
    }

    private static func setOption(
        handle: OpaquePointer,
        name: String,
        value: String
    ) throws {
        let result = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
        guard result >= 0 else {
            throw MPVIntegrationError.optionSettingFailed(name: name, code: result)
        }
    }

    private static func runCommand(
        handle: OpaquePointer,
        arguments: [String]
    ) throws {
        let allocated = arguments.map { strdup($0) }
        guard allocated.allSatisfy({ $0 != nil }) else {
            allocated.forEach { free($0) }
            throw MPVIntegrationError.memoryAllocationFailed
        }
        defer { allocated.forEach { free($0) } }

        var pointers: [UnsafePointer<CChar>?] = allocated.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        pointers.append(nil)

        let result = pointers.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
        }
        guard result >= 0 else {
            throw MPVIntegrationError.commandFailed(code: result)
        }
    }
}

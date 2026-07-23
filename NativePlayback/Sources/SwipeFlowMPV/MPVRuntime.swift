import CMPV
import Foundation

public struct MPVAPIVersion: Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(encodedValue: UInt) {
        major = Int(encodedValue >> 16)
        minor = Int(encodedValue & 0xffff)
    }

    public var description: String {
        "\(major).\(minor)"
    }
}

public enum MPVIntegrationError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleClientAPI(compiled: MPVAPIVersion, runtime: MPVAPIVersion)
    case clientCreationFailed
    case optionSettingFailed(name: String, code: Int32)
    case initializationFailed(code: Int32)
    case commandFailed(code: Int32)
    case propertyReadFailed(name: String, code: Int32)
    case renderContextCreationFailed(code: Int32)
    case renderingFailed(code: Int32)
    case openGLUnavailable
    case mediaLoadFailed(code: Int32)
    case mediaLoadTimedOut(seconds: Int)
    case memoryAllocationFailed
    case httpHeadersNotYetSupported

    public var errorDescription: String? {
        switch self {
        case let .incompatibleClientAPI(compiled, runtime):
            "The libmpv client API is incompatible (compiled for \(compiled), runtime \(runtime))."
        case .clientCreationFailed:
            "libmpv could not create a client instance."
        case let .optionSettingFailed(name, code):
            "libmpv rejected the \(name) option with error \(code)."
        case let .initializationFailed(code):
            "libmpv initialization failed with error \(code)."
        case let .commandFailed(code):
            "A libmpv command failed with error \(code)."
        case let .propertyReadFailed(name, code):
            "libmpv could not read the \(name) property (error \(code))."
        case let .renderContextCreationFailed(code):
            "The libmpv OpenGL render context could not be created (error \(code))."
        case let .renderingFailed(code):
            "libmpv could not render the current frame (error \(code))."
        case .openGLUnavailable:
            "A compatible macOS OpenGL context is unavailable."
        case let .mediaLoadFailed(code):
            "libmpv could not load the media resource (error \(code))."
        case let .mediaLoadTimedOut(seconds):
            "媒体在 \(seconds) 秒内没有完成加载，远端存储可能响应较慢或暂时不可用。"
        case .memoryAllocationFailed:
            "Memory allocation failed while preparing a libmpv command."
        case .httpHeadersNotYetSupported:
            "Transient HTTP headers are not supported by this playback adapter yet."
        }
    }
}

public enum MPVRuntime {
    public static var compiledClientAPIVersion: MPVAPIVersion {
        MPVAPIVersion(encodedValue: UInt(swipeflow_mpv_compiled_client_api_version()))
    }

    public static var runtimeClientAPIVersion: MPVAPIVersion {
        MPVAPIVersion(encodedValue: UInt(mpv_client_api_version()))
    }

    public static func validateClientAPI() throws {
        let compiled = compiledClientAPIVersion
        let runtime = runtimeClientAPIVersion
        guard compiled.major == runtime.major, runtime.minor >= compiled.minor else {
            throw MPVIntegrationError.incompatibleClientAPI(
                compiled: compiled,
                runtime: runtime
            )
        }
    }
}

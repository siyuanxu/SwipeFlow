import Foundation
import SwipeFlowCore

public struct MPVPlaybackDiagnostics: Equatable, Sendable {
    public var route: [PlaybackRouteStep] = []
    public var container: String?
    public var videoCodec: String?
    public var pixelFormat: String?
    public var width: Int?
    public var height: Int?
    public var framesPerSecond: Double?
    public var videoBitrate: Double?
    public var audioCodec: String?
    public var audioBitrate: Double?
    public var hardwareDecoder: String?
    public var cacheDuration: TimeInterval?
    public var cachePercent: Double?
    public var pausedForCache: Bool?
    public var droppedFrames: Int?
    public var audioVideoSync: Double?
    public var errorMessage: String?
    public var loadTimeout: TimeInterval?
    public var networkProbeStatus: String?
    public var networkResponseTime: TimeInterval?
    public var networkContentType: String?
    public var networkContentLength: Int64?
    public var networkAcceptsByteRanges: Bool?

    public init() {}
}

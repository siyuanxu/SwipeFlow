import AppKit
import Foundation
import OpenGL.GL3
import XCTest
import SwipeFlowCore
@testable import SwipeFlowMPV

final class MPVPlaybackEngineTests: XCTestCase {
    func testDefaultConfigurationTargetsFifteenSecondsOfMemoryCache() {
        let configuration = MPVConfiguration()
        XCTAssertEqual(configuration.cacheSeconds, 15)
        XCTAssertEqual(configuration.cacheByteLimit, 64 * 1_024 * 1_024)
        XCTAssertTrue(configuration.startMuted)
        XCTAssertEqual(configuration.localLoadTimeout, 15)
        XCTAssertEqual(configuration.remoteLoadTimeout, 45)
    }

    func testRuntimeClientAPIIsCompatible() throws {
        XCTAssertNoThrow(try MPVRuntime.validateClientAPI())
        XCTAssertEqual(MPVRuntime.compiledClientAPIVersion.major, 2)
        XCTAssertGreaterThanOrEqual(
            MPVRuntime.runtimeClientAPIVersion.minor,
            MPVRuntime.compiledClientAPIVersion.minor
        )
    }

    @MainActor
    func testOpenGLRenderContextCanBeCreatedAndShutDown() throws {
        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .renderAPI)
        )
        guard engine.openGLContextForRendering != nil else {
            throw XCTSkip("OpenGL is unavailable in this headless test environment")
        }

        try engine.draw(width: 16, height: 16)
    }

    @MainActor
    func testHeadlessEngineLoadsLocalMediaPaused() async throws {
        let mediaURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .headless)
        )
        try await engine.load(
            PlaybackResource(
                url: mediaURL,
                diagnosticRoute: [
                    PlaybackRouteStep(label: "测试输入", redactedAddress: "本地测试文件")
                ]
            )
        )

        XCTAssertEqual(engine.state, .paused(position: 0))
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.diagnostics.route.first?.label, "测试输入")
        XCTAssertNotNil(engine.diagnostics.container)
        XCTAssertNotNil(engine.diagnostics.audioCodec)

        engine.play()
        let didPlay = await waitUntil {
            if case .playing = engine.state { true } else { false }
        }
        XCTAssertTrue(didPlay)

        engine.seek(to: 0.05)
        let didSeek = await waitUntil {
            engine.state == .playing(position: 0.05)
        }
        XCTAssertTrue(didSeek)

        engine.pause()
        let didPause = await waitUntil {
            engine.state == .paused(position: 0.05)
        }
        XCTAssertTrue(didPause)

        engine.unload()
        let didUnload = await waitUntil { engine.state == .idle }
        XCTAssertTrue(didUnload)
    }

    @MainActor
    func testMutedStatePersistsWhenReplacingMedia() async throws {
        let mediaURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .headless)
        )
        let resource = PlaybackResource(url: mediaURL)

        try await engine.load(resource)
        XCTAssertTrue(engine.isMuted)

        engine.setMuted(false)
        let didUnmute = await waitUntil { !engine.isMuted }
        XCTAssertTrue(didUnmute)

        try await engine.load(resource)
        XCTAssertFalse(engine.isMuted)
    }

    @MainActor
    func testTemporaryPlaybackRateCanReturnToNormal() async throws {
        let mediaURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .headless)
        )
        try await engine.load(PlaybackResource(url: mediaURL))

        engine.setPlaybackRate(2)
        let didAccelerate = await waitUntil { engine.playbackRate == 2 }
        XCTAssertTrue(didAccelerate)

        engine.setPlaybackRate(1)
        let didRestore = await waitUntil { engine.playbackRate == 1 }
        XCTAssertTrue(didRestore)
    }

    @MainActor
    func testRenderContextCreatedBeforeLoadProducesVideoPixels() async throws {
        let mediaURL = try makeColorY4M()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(
                videoOutput: .renderAPI,
                hardwareDecoding: "no"
            )
        )
        guard let context = engine.openGLContextForRendering else {
            throw XCTSkip("An offscreen OpenGL surface is unavailable")
        }
        context.makeCurrentContext()
        var texture: GLuint = 0
        var framebuffer: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(
            GLenum(GL_TEXTURE_2D),
            0,
            GL_RGBA8,
            64,
            64,
            0,
            GLenum(GL_RGBA),
            GLenum(GL_UNSIGNED_BYTE),
            nil
        )
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER),
            GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_2D),
            texture,
            0
        )
        XCTAssertEqual(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)), GLenum(GL_FRAMEBUFFER_COMPLETE))
        defer {
            context.makeCurrentContext()
            glDeleteFramebuffers(1, &framebuffer)
            glDeleteTextures(1, &texture)
        }

        try await engine.load(PlaybackResource(url: mediaURL))
        engine.play()

        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let renderedPixels = await waitUntil(timeout: .seconds(3)) {
            do {
                try engine.draw(
                    width: 64,
                    height: 64,
                    framebuffer: Int32(framebuffer)
                )
            } catch {
                return false
            }
            context.makeCurrentContext()
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            glReadPixels(
                0,
                0,
                64,
                64,
                GLenum(GL_RGBA),
                GLenum(GL_UNSIGNED_BYTE),
                &pixels
            )
            return pixels.enumerated().contains { index, value in
                index % 4 != 3 && value > 24
            }
        }

        XCTAssertTrue(renderedPixels, "Expected libmpv to render a non-black video frame")
    }

    @MainActor
    func testEngineRejectsHTTPHeadersUntilTheyCanBeClearedSafely() async throws {
        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .headless)
        )
        let resource = PlaybackResource(
            url: URL(string: "https://media.example.invalid/video.mp4")!,
            httpHeaders: ["X-Playback-Authorization": "example-placeholder"]
        )

        do {
            try await engine.load(resource)
            XCTFail("Expected transient headers to be rejected")
        } catch let error as MPVIntegrationError {
            XCTAssertEqual(error, .httpHeadersNotYetSupported)
        }
    }

    @MainActor
    func testEngineCanReplaceAnAlreadyLoadedResource() async throws {
        let firstURL = try makeSilentWAV()
        let secondURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .headless)
        )
        try await engine.load(PlaybackResource(url: firstURL))
        try await engine.load(PlaybackResource(url: secondURL))

        XCTAssertEqual(engine.state, .paused(position: 0))
        engine.unload()
    }

    @MainActor
    func testFailedLoadDoesNotExposeTheLocalPath() async throws {
        let engine = try MPVPlaybackEngine(
            configuration: MPVConfiguration(videoOutput: .headless)
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-placeholder-\(UUID().uuidString).mp4")

        do {
            try await engine.load(PlaybackResource(url: missingURL))
            XCTFail("Expected a missing media file to fail")
        } catch {
            guard case let .failed(message) = engine.state else {
                return XCTFail("Expected the engine to enter a failed state")
            }
            XCTAssertFalse(message.contains(missingURL.path))
            XCTAssertFalse(message.contains(missingURL.lastPathComponent))
        }
    }

    private func makeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwipeFlowMPV-\(UUID().uuidString).wav")
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = 80_000
        let dataSize = sampleCount * 2

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeColorY4M() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwipeFlowMPV-\(UUID().uuidString).y4m")
        let width = 32
        let height = 32
        var data = Data("YUV4MPEG2 W\(width) H\(height) F30:1 Ip A1:1 C420jpeg\n".utf8)
        let luma = Data(repeating: 150, count: width * height)
        let chromaU = Data(repeating: 54, count: width * height / 4)
        let chromaV = Data(repeating: 200, count: width * height / 4)
        for _ in 0..<90 {
            data.append(contentsOf: "FRAME\n".utf8)
            data.append(luma)
            data.append(chromaU)
            data.append(chromaV)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

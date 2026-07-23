import AppKit
import CMPV
import Foundation
import OpenGL.GL3

private func mpvOpenGLUpdateCallback(_ opaqueContext: UnsafeMutableRawPointer?) {
    guard let opaqueContext else { return }
    let bridge = Unmanaged<MPVRenderUpdateBridge>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    bridge.signal()
}

private final class MPVRenderUpdateBridge: @unchecked Sendable {
    private var isActive = true
    private let requestDisplay: @MainActor () -> Void

    @MainActor
    init(requestDisplay: @escaping @MainActor () -> Void) {
        self.requestDisplay = requestDisplay
    }

    nonisolated func signal() {
        DispatchQueue.main.async { [weak self] in
            self?.deliver()
        }
    }

    @MainActor
    func invalidate() {
        isActive = false
    }

    @MainActor
    private func deliver() {
        guard isActive else { return }
        requestDisplay()
    }
}

final class MPVOpenGLRenderer {
    private let client: MPVClient
    private let openGLContext: NSOpenGLContext
    private let updateBridge: MPVRenderUpdateBridge
    private var renderContext: OpaquePointer?

    @MainActor
    init(
        client: MPVClient,
        openGLContext: NSOpenGLContext,
        requestDisplay: @escaping @MainActor () -> Void
    ) throws {
        self.client = client
        self.openGLContext = openGLContext
        updateBridge = MPVRenderUpdateBridge(requestDisplay: requestDisplay)

        var createdContext: OpaquePointer?
        let result = try withCurrentOpenGLContext {
            swipeflow_mpv_create_opengl_render_context(&createdContext, client.handle)
        }
        guard result >= 0, let createdContext else {
            throw MPVIntegrationError.renderContextCreationFailed(code: result)
        }
        renderContext = createdContext

        mpv_render_context_set_update_callback(
            createdContext,
            mpvOpenGLUpdateCallback,
            Unmanaged.passUnretained(updateBridge).toOpaque()
        )
    }

    @MainActor
    func draw(width: Int, height: Int, framebuffer: Int32 = 0) throws {
        guard let renderContext, width > 0, height > 0 else { return }
        let clampedWidth = min(width, Int(Int32.max))
        let clampedHeight = min(height, Int(Int32.max))

        try withCurrentOpenGLContext {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            _ = mpv_render_context_update(renderContext)
            let result = swipeflow_mpv_render_opengl_frame(
                renderContext,
                framebuffer,
                Int32(clampedWidth),
                Int32(clampedHeight)
            )
            guard result >= 0 else {
                throw MPVIntegrationError.renderingFailed(code: result)
            }
            openGLContext.flushBuffer()
            mpv_render_context_report_swap(renderContext)
        }
    }

    @MainActor
    func shutdown() {
        guard let renderContext else { return }
        updateBridge.invalidate()
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        do {
            try withCurrentOpenGLContext {
                mpv_render_context_free(renderContext)
            }
            self.renderContext = nil
        } catch {
            return
        }
    }

    deinit {
        if let renderContext {
            openGLContext.makeCurrentContext()
            if let cglContext = openGLContext.cglContextObj {
                CGLLockContext(cglContext)
                mpv_render_context_set_update_callback(renderContext, nil, nil)
                mpv_render_context_free(renderContext)
                CGLUnlockContext(cglContext)
            }
        }
    }

    @MainActor
    private func withCurrentOpenGLContext<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        openGLContext.makeCurrentContext()
        guard let cglContext = openGLContext.cglContextObj else {
            throw MPVIntegrationError.openGLUnavailable
        }
        CGLLockContext(cglContext)
        defer { CGLUnlockContext(cglContext) }
        return try operation()
    }
}

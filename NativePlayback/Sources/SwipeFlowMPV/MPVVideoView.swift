import AppKit
import SwiftUI

@MainActor
public struct MPVVideoView: NSViewRepresentable {
    public let engine: MPVPlaybackEngine
    public let cornerRadius: CGFloat

    public init(engine: MPVPlaybackEngine, cornerRadius: CGFloat = 20) {
        self.engine = engine
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSView {
        guard let view = MPVVideoContainerView(
            engine: engine,
            cornerRadius: cornerRadius
        ) else {
            engine.reportRenderingFailure(MPVIntegrationError.openGLUnavailable)
            let fallback = NSTextField(
                labelWithString: MPVIntegrationError.openGLUnavailable.localizedDescription
            )
            fallback.alignment = .center
            fallback.textColor = .secondaryLabelColor
            fallback.drawsBackground = true
            fallback.backgroundColor = .black
            return fallback
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MPVVideoContainerView)?.cornerRadius = cornerRadius
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MPVVideoContainerView)?.shutdown()
    }
}

/// AppKit owns the OpenGL surface, so SwiftUI's `clipShape` alone cannot
/// reliably clip its four corners. This native layer-backed container applies
/// the mask at the same compositing level as the video surface.
@MainActor
final class MPVVideoContainerView: NSView {
    var cornerRadius: CGFloat {
        didSet { updateLayerAppearance() }
    }

    private let videoView: MPVOpenGLView

    init?(engine: MPVPlaybackEngine, cornerRadius: CGFloat) {
        guard let videoView = MPVOpenGLView(engine: engine) else { return nil }
        self.videoView = videoView
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        updateLayerAppearance()

        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isOpaque: Bool { false }

    func shutdown() {
        videoView.shutdown()
    }

    private func updateLayerAppearance() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        // The native layer owns clipping for the OpenGL surface. The SwiftUI
        // container draws the single visible border; drawing it here as well
        // can expose a second arc when the two compositing layers round pixels
        // differently on Retina displays.
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }
}

@MainActor
final class MPVOpenGLView: NSOpenGLView {
    private let engine: MPVPlaybackEngine

    init?(engine: MPVPlaybackEngine) {
        self.engine = engine
        guard let context = engine.openGLContextForRendering else {
            return nil
        }
        super.init(frame: .zero, pixelFormat: context.pixelFormat)
        openGLContext = context
        wantsBestResolutionOpenGLSurface = true
        engine.attachRenderingView(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isOpaque: Bool { true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard let openGLContext else {
            engine.reportRenderingFailure(MPVIntegrationError.openGLUnavailable)
            return
        }

        var swapInterval: Int32 = 1
        openGLContext.setValues(&swapInterval, for: .swapInterval)
        needsDisplay = true
    }

    override func reshape() {
        super.reshape()
        openGLContext?.update()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let backingBounds = convertToBacking(bounds)
        do {
            try engine.draw(
                width: Int(backingBounds.width.rounded(.up)),
                height: Int(backingBounds.height.rounded(.up))
            )
        } catch {
            engine.reportRenderingFailure(error)
        }
    }

    func shutdown() {
        engine.detachRenderingView(self)
    }

}

func makeMPVOpenGLPixelFormat() -> NSOpenGLPixelFormat? {
    let attributes: [NSOpenGLPixelFormatAttribute] = [
        UInt32(NSOpenGLPFAOpenGLProfile),
        UInt32(NSOpenGLProfileVersion3_2Core),
        UInt32(NSOpenGLPFAAccelerated),
        UInt32(NSOpenGLPFADoubleBuffer),
        UInt32(NSOpenGLPFAColorSize),
        24,
        UInt32(NSOpenGLPFAAlphaSize),
        8,
        0,
    ]
    return NSOpenGLPixelFormat(attributes: attributes)
}

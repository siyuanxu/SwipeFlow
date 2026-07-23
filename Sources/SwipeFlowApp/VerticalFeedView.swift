import SwiftUI
import SwipeFlowCore
import SwipeFlowMPV

@MainActor
private final class FeedPlaybackCoordinator: ObservableObject {
    @Published private var revision = 0

    private lazy var pool = PlaybackPool(
        buildEngine: { try MPVPlaybackEngine() },
        didChange: { [weak self] in
            self?.revision &+= 1
        }
    )

    func focus(
        on index: Int,
        items: [MediaItem],
        resolve: @escaping PlaybackPool.ResourceResolver
    ) async {
        await pool.focus(on: index, items: items, resolve: resolve)
    }

    func engine(for reference: MediaReference) -> MPVPlaybackEngine? {
        _ = revision
        return pool.engine(for: reference) as? MPVPlaybackEngine
    }

    func failure(for reference: MediaReference) -> PlaybackPreparationFailure? {
        _ = revision
        return pool.failures[reference]
    }
}

struct VerticalFeedView: View {
    let items: [MediaItem]
    let retentionByReference: [MediaReference: RetentionState]
    let favoriteReferences: Set<MediaReference>
    let resolve: PlaybackPool.ResourceResolver
    let review: @MainActor (MediaReviewChoice, MediaItem) async -> Bool

    @State private var focusedID: MediaReference?
    @State private var retryRevision = 0
    @StateObject private var playback = FeedPlaybackCoordinator()

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    FeedPage(
                        item: item,
                        isFocused: item.reference == focusedID,
                        engine: playback.engine(for: item.reference),
                        preparationFailure: playback.failure(for: item.reference),
                        retention: retentionByReference[item.reference],
                        isFavorite: favoriteReferences.contains(item.reference),
                        review: { choice in
                            Task {
                                if await review(choice, item) {
                                    moveFocus(by: 1)
                                }
                            }
                        },
                        retry: { retryRevision &+= 1 }
                    )
                        .containerRelativeFrame(.vertical)
                        .id(item.reference)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $focusedID)
        .background(.black)
        .overlay(alignment: .trailing) {
            VStack(spacing: 0) {
                Button {
                    moveFocus(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 34, height: 30)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(focusedIndex == 0)

                Divider()
                    .frame(width: 20)
                    .overlay(.white.opacity(0.14))

                Button {
                    moveFocus(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 34, height: 30)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(focusedIndex >= items.count - 1)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .padding(.trailing, 28)
        }
        .onAppear {
            if focusedID == nil {
                focusedID = items.first?.reference
            }
        }
        .onChange(of: items.map(\.reference)) { _, references in
            if let focusedID, references.contains(focusedID) {
                return
            }
            focusedID = references.first
        }
        .task(
            id: FocusRequest(
                focusedID: focusedID,
                items: items.map(\.reference),
                retryRevision: retryRevision
            )
        ) {
            guard let focusedID,
                  let index = items.firstIndex(where: { $0.reference == focusedID }) else {
                return
            }
            await playback.focus(on: index, items: items, resolve: resolve)
        }
    }

    private struct FocusRequest: Hashable {
        let focusedID: MediaReference?
        let items: [MediaReference]
        let retryRevision: Int
    }

    private var focusedIndex: Int {
        guard let focusedID else { return 0 }
        return items.firstIndex(where: { $0.reference == focusedID }) ?? 0
    }

    private func moveFocus(by offset: Int) {
        let destination = min(max(focusedIndex + offset, 0), items.count - 1)
        guard items.indices.contains(destination) else { return }
        withAnimation(.snappy(duration: 0.22)) {
            focusedID = items[destination].reference
        }
    }
}

private struct FeedPage: View {
    let item: MediaItem
    let isFocused: Bool
    let engine: MPVPlaybackEngine?
    let preparationFailure: PlaybackPreparationFailure?
    let retention: RetentionState?
    let isFavorite: Bool
    let review: (MediaReviewChoice) -> Void
    let retry: () -> Void

    @State private var isFileInfoHovered = false
    @State private var showingPlaybackDiagnostics = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                VStack(spacing: 10) {
                    Group {
                        if let engine {
                            AspectFittedVideoView(engine: engine, cornerRadius: 20)
                        } else {
                            LinearGradient(
                                colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .overlay {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 30)
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            // A nearly invisible fill keeps this hover target active
                            // even while the information card itself is faded out.
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.001))

                            if isFocused && !isFileInfoHovered {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.42))
                                    .padding(10)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(isFocused ? "正在播放" : "已预载")
                                    if let detailText = item.detailText {
                                        Text("·")
                                        Text(detailText)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))

                                if isFocused {
                                    Text(item.reference.itemID.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.64))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(item.reference.itemID.rawValue)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            }
                            .opacity(!isFocused || isFileInfoHovered ? 1 : 0)
                        }
                        .frame(maxWidth: 430, alignment: .leading)
                        .frame(minHeight: 62, alignment: .topLeading)
                        .padding(.horizontal, 16)
                        .offset(y: 18)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onHover { hovering in
                            guard isFocused else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isFileInfoHovered = hovering
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isFocused {
                            ReviewControls(
                                retention: retention,
                                isFavorite: isFavorite,
                                choose: review
                            )
                            .padding(.horizontal, 16)
                            .offset(y: 18)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isFocused {
                        if let engine {
                            PlaybackControls(
                                engine: engine,
                                retry: retry,
                                showDiagnostics: { showingPlaybackDiagnostics = true }
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            PlaybackUnavailableControls(
                                failure: preparationFailure,
                                retry: retry,
                                showDiagnostics: { showingPlaybackDiagnostics = true }
                            )
                        }
                    }
                }
                .frame(
                    width: max(proxy.size.width - 28, 1),
                    height: max(proxy.size.height - 28, 1)
                )
            }
            .foregroundStyle(.white)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    isFileInfoHovered = false
                }
            }
            .sheet(isPresented: $showingPlaybackDiagnostics) {
                PlaybackDiagnosticsView(
                    item: item,
                    engine: engine,
                    preparationFailure: preparationFailure,
                    retry: retry
                )
            }
        }
    }
}

private struct AspectFittedVideoView: View {
    @ObservedObject var engine: MPVPlaybackEngine
    let cornerRadius: CGFloat

    var body: some View {
        MPVVideoView(engine: engine, cornerRadius: cornerRadius)
            .aspectRatio(displayAspectRatio, contentMode: .fit)
    }

    private var displayAspectRatio: CGFloat {
        guard let width = engine.diagnostics.width,
              let height = engine.diagnostics.height,
              width > 0,
              height > 0 else {
            return 16 / 9
        }
        return CGFloat(width) / CGFloat(height)
    }
}

private struct ReviewControls: View {
    let retention: RetentionState?
    let isFavorite: Bool
    let choose: (MediaReviewChoice) -> Void

    var body: some View {
        HStack(spacing: 3) {
            reviewButton(
                "喜欢",
                systemImage: isFavorite ? "heart.fill" : "heart",
                isSelected: isFavorite,
                tint: .yellow,
                choice: .favorite
            )
            .keyboardShortcut("l", modifiers: [])
            .help("喜欢或取消喜欢（L）")

            reviewButton(
                "待删除",
                systemImage: "trash",
                isSelected: retention == .reviewForDeletion,
                tint: .red,
                choice: .reviewForDeletion
            )
            .keyboardShortcut("d", modifiers: [])
            .help("加入待删除或撤回（D）")
        }
        .padding(4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func reviewButton(
        _ title: String,
        systemImage: String,
        isSelected: Bool,
        tint: Color,
        choice: MediaReviewChoice
    ) -> some View {
        Button {
            choose(choice)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    isSelected ? tint.opacity(0.20) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? tint : .white.opacity(0.84))
    }
}

private struct PlaybackControls: View {
    @ObservedObject var engine: MPVPlaybackEngine
    let retry: () -> Void
    let showDiagnostics: () -> Void
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var isPointerInControls = false

    var body: some View {
        ZStack {
            // Keep only the control-bar region as the hover target while the
            // glass itself is faded out.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.001))

            VStack(spacing: 7) {
                if isFailed {
                    HStack(spacing: 8) {
                        Label("播放失败", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Spacer()
                        Button("重试播放", action: retry)
                            .buttonStyle(.bordered)
                    }
                    .font(.caption.weight(.semibold))
                }

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : engine.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...maximumDuration,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            scrubPosition = engine.position
                        } else {
                            engine.seek(to: scrubPosition)
                        }
                    }
                )
                .tint(.white)
                .disabled(!canControlPlayback)

                HStack(spacing: 12) {
                    Text(formatTime(isScrubbing ? scrubPosition : engine.position))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.72))

                    Spacer()

                    Button {
                        engine.seek(to: max(0, engine.position - maximumDuration * 0.05))
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!canControlPlayback)
                    .help("后退视频时长的 5%（←）")

                    Button {
                        engine.isPlaying ? engine.pause() : engine.play()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.callout)
                            .frame(width: 26, height: 24)
                            .background(.white.opacity(0.13), in: Circle())
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!canControlPlayback)

                    Button {
                        engine.seek(to: min(maximumDuration, engine.position + maximumDuration * 0.05))
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!canControlPlayback)
                    .help("前进视频时长的 5%（→）")

                    Button {
                        engine.setMuted(!engine.isMuted)
                    } label: {
                        Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .keyboardShortcut("m", modifiers: [])
                    .help(engine.isMuted ? "打开声音" : "静音")

                    Spacer()

                    Text(formatTime(engine.duration))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.72))

                    Button(action: showDiagnostics) {
                        Label("播放信息", systemImage: "waveform.path.ecg")
                    }
                    .help("查看编码、码率、缓存与地址跳转")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .modifier(PlaybackGlassModifier(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .opacity(controlsAreVisible ? 1 : 0)
            .allowsHitTesting(controlsAreVisible)
        }
        // The transparent hover target must keep an intrinsic, fixed height.
        // A flexible ZStack would otherwise consume the feed's remaining
        // vertical space and shrink the video viewport.
        .frame(height: 66)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isPointerInControls = hovering
            }
        }
    }

    private var controlsAreVisible: Bool {
        isPointerInControls || isScrubbing || isFailed
    }

    private var maximumDuration: Double {
        max(engine.duration, engine.position, 0.01)
    }

    private var canControlPlayback: Bool {
        switch engine.state {
        case .playing, .paused: true
        default: false
        }
    }

    private var isFailed: Bool {
        if case .failed = engine.state { return true }
        return false
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct PlaybackGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
        }
    }
}

private struct PlaybackUnavailableControls: View {
    let failure: PlaybackPreparationFailure?
    let retry: () -> Void
    let showDiagnostics: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if failure == nil {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            Text(statusText)
                .font(.caption)
            Spacer()
            if failure != nil {
                Button("重试播放", action: retry)
                    .buttonStyle(.plain)
            }
            Button(action: showDiagnostics) {
                Label("播放信息", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .foregroundStyle(.white)
        .modifier(PlaybackGlassModifier(cornerRadius: 16))
    }

    private var statusText: String {
        switch failure {
        case .resourceResolutionFailed: "无法取得播放地址"
        case .engineCreationFailed: "播放器初始化失败"
        case .engineLoadingFailed: "视频加载失败"
        case nil: "正在准备视频…"
        }
    }
}

private struct PlaybackDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    let engine: MPVPlaybackEngine?
    let preparationFailure: PlaybackPreparationFailure?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("播放调试信息")
                        .font(.title2.bold())
                    Text(item.title)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hasFailed {
                    Button("重试播放") {
                        retry()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("完成") { dismiss() }
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    diagnosticSection("当前文件") {
                        diagnosticRow("文件名", item.title)
                        diagnosticRow("媒体路径", item.reference.itemID.rawValue)
                    }

                    if let engine {
                        LivePlaybackDiagnostics(engine: engine)
                    } else {
                        diagnosticSection("播放状态") {
                            diagnosticRow("状态", preparationFailureText)
                            Text("播放器尚未取得可读取的媒体地址，因此暂时没有编码和码率数据。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("安全提示：账号、Cookie、Token、签名和查询参数已隐藏；本页信息只在内存中显示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .textSelection(.enabled)
    }

    private var preparationFailureText: String {
        switch preparationFailure {
        case .resourceResolutionFailed: "播放地址解析失败"
        case .engineCreationFailed: "libmpv 初始化失败"
        case .engineLoadingFailed: "libmpv 加载视频失败"
        case nil: "正在准备"
        }
    }

    private var hasFailed: Bool {
        if preparationFailure != nil { return true }
        guard let engine else { return false }
        if case .failed = engine.state { return true }
        return false
    }
}

private struct LivePlaybackDiagnostics: View {
    @ObservedObject var engine: MPVPlaybackEngine

    var body: some View {
        let info = engine.diagnostics

        diagnosticSection("播放状态") {
            diagnosticRow("状态", stateText)
            if let error = info.errorMessage {
                diagnosticRow("错误", error, valueColor: .red)
            }
            diagnosticRow("加载等待上限", formatDuration(info.loadTimeout))
            diagnosticRow("网络检测", info.networkProbeStatus ?? probePendingText(info))
            diagnosticRow("首响应时间", formatDuration(info.networkResponseTime))
            diagnosticRow("内容类型", info.networkContentType ?? "—")
            diagnosticRow("响应数据量", formatByteCount(info.networkContentLength))
            diagnosticRow(
                "支持分段读取",
                info.networkAcceptsByteRanges.map { $0 ? "是" : "否" } ?? "—"
            )
            diagnosticRow("缓存暂停", info.pausedForCache.map { $0 ? "是" : "否" } ?? "—")
            diagnosticRow("已缓存时长", formatDuration(info.cacheDuration))
            diagnosticRow("缓存进度", formatPercent(info.cachePercent))
            diagnosticRow("丢帧", info.droppedFrames.map(String.init) ?? "—")
            diagnosticRow("音画偏差", formatSync(info.audioVideoSync))
        }

        diagnosticSection("视频与音频") {
            diagnosticRow("容器", info.container ?? "—")
            diagnosticRow("视频编码", info.videoCodec ?? "—")
            diagnosticRow("像素格式", info.pixelFormat ?? "—")
            diagnosticRow("分辨率", resolutionText(info))
            diagnosticRow("帧率", formatFPS(info.framesPerSecond))
            diagnosticRow("视频码率", formatBitrate(info.videoBitrate))
            diagnosticRow("硬件解码", hardwareDecoderText(info.hardwareDecoder))
            diagnosticRow("音频编码", info.audioCodec ?? "—")
            diagnosticRow("音频码率", formatBitrate(info.audioBitrate))
        }

        diagnosticSection("地址跳转") {
            if info.route.isEmpty {
                Text("尚未取得播放地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(info.route.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: index == info.route.count - 1 ? "play.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(index == info.route.count - 1 ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.label)
                                .font(.caption.weight(.semibold))
                            Text(step.redactedAddress)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var stateText: String {
        switch engine.state {
        case .idle: "空闲"
        case .loading: "正在加载"
        case .paused: "已暂停"
        case .playing: "正在播放"
        case .failed: "播放失败"
        }
    }

    private func resolutionText(_ info: MPVPlaybackDiagnostics) -> String {
        guard let width = info.width, let height = info.height else { return "—" }
        return "\(width) × \(height)"
    }

    private func formatFPS(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2)))) fps"
    }

    private func formatBitrate(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        if value >= 1_000_000 {
            return "\((value / 1_000_000).formatted(.number.precision(.fractionLength(2)))) Mbps"
        }
        return "\((value / 1_000).formatted(.number.precision(.fractionLength(0...1)))) Kbps"
    }

    private func formatDuration(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) 秒"
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func formatSync(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(3)))) 秒"
    }

    private func formatByteCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func probePendingText(_ info: MPVPlaybackDiagnostics) -> String {
        guard info.errorMessage != nil else { return "—" }
        return "正在检测…"
    }

    private func hardwareDecoderText(_ value: String?) -> String {
        guard let value else { return "—" }
        return value == "no" ? "软件解码" : value
    }
}

@ViewBuilder
private func diagnosticSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 11) {
        Text(title)
            .font(.headline)
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private func diagnosticRow(
    _ label: String,
    _ value: String,
    valueColor: Color = .primary
) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(label)
            .foregroundStyle(.secondary)
            .frame(width: 94, alignment: .leading)
        Text(value)
            .foregroundStyle(valueColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.callout)
}

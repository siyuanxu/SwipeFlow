import AppKit
import SwiftUI
import SwipeFlowConnectors
import SwipeFlowCore
import UniformTypeIdentifiers

enum SourceKind: String, Identifiable {
    case localVideo
    case strm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localVideo: "本地视频目录"
        case .strm: ".strm 目录"
        }
    }

    var systemImage: String {
        switch self {
        case .localVideo: "folder.fill"
        case .strm: "doc.text.fill"
        }
    }
}

enum VidpickConnectionStatus: Equatable {
    case notConfigured
    case restoring
    case connected
    case needsAttention
}

enum MediaReviewChoice: Equatable, Sendable {
    case favorite
    case reviewForDeletion
}

@MainActor
final class SourceBrowserModel: ObservableObject {
    @Published private(set) var sourceName = "尚未选择媒体来源"
    @Published private(set) var sourceDetail: String?
    @Published private(set) var sourceSystemImage = "rectangle.stack.badge.play"
    @Published var items: [MediaItem] = []
    @Published var message = "选择本地视频目录或 .strm 目录开始浏览。"
    @Published private(set) var vidpickStatus: VidpickConnectionStatus
    @Published private(set) var isBrowsingVidpick = false
    @Published private(set) var retentionByReference: [MediaReference: RetentionState] = [:]
    @Published private(set) var favoriteReferences: Set<MediaReference> = []
    @Published private(set) var isReviewActionRunning = false

    private var source: (any MediaSource)?
    private var securityScopedURL: URL?
    private var vidpickSource: VidpickSource?
    private var vidpickItems: [MediaItem] = []
    private var vidpickReviewSnapshot = VidpickReviewSnapshot(retention: [:], favorites: [])
    private var cachedVidpickCredentials: (account: String, credentials: VidpickCredentials)?
    private var hasAttemptedVidpickRestore = false

    init() {
        vidpickStatus = VidpickProfileStore.load() == nil ? .notConfigured : .restoring
    }

    func open(_ url: URL, as kind: SourceKind) {
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = url
        }
        Task {
            do {
                let sourceID = MediaSourceID(rawValue: UUID().uuidString)
                let displayName = url.lastPathComponent
                let selectedSource: any MediaSource
                switch kind {
                case .localVideo:
                    selectedSource = try LocalVideoSource(
                        id: sourceID,
                        displayName: displayName,
                        rootURL: url
                    )
                case .strm:
                    selectedSource = try STRMFolderSource(
                        id: sourceID,
                        displayName: displayName,
                        rootURL: url
                    )
                }

                let loadedItems = try await fetchAllItems(from: selectedSource)
                source = selectedSource
                isBrowsingVidpick = false
                sourceName = displayName
                sourceDetail = url.path(percentEncoded: false)
                sourceSystemImage = kind.systemImage
                retentionByReference = [:]
                favoriteReferences = []
                items = loadedItems
                message = loadedItems.isEmpty
                    ? "目录中没有发现支持的媒体。"
                    : "已载入 \(loadedItems.count) 项。"
            } catch {
                source = nil
                items = []
                message = error.localizedDescription
            }
        }
    }

    func resolvePlayback(for reference: MediaReference) async throws -> PlaybackResource {
        guard let source else {
            throw MediaSourceError.sourceNotFound(reference.sourceID)
        }
        guard source.descriptor.id == reference.sourceID else {
            throw MediaSourceError.itemSourceMismatch
        }
        return try await source.resolvePlayback(for: reference.itemID)
    }

    func connectVidpick(_ input: VidpickConnectionInput) async throws {
        guard let baseURL = URL(string: input.serverAddress) else {
            throw VidpickConnectorError.invalidServerURL
        }
        let sourceID = MediaSourceID(rawValue: UUID().uuidString)
        let configuration = try VidpickConfiguration(
            id: sourceID,
            displayName: "Vidpick",
            baseURL: baseURL,
            folderPath: input.folderPath.isEmpty ? "/" : input.folderPath,
            recursive: input.recursive
        )
        let account = VidpickCredentialStore.account(
            baseURL: configuration.baseURL,
            username: input.username
        )
        let password: String
        if !input.password.isEmpty {
            password = input.password
        } else if let cachedVidpickCredentials,
                  cachedVidpickCredentials.account == account {
            password = cachedVidpickCredentials.credentials.password
        } else {
            password = try VidpickCredentialStore.loadPassword(account: account)
        }
        let credentials = VidpickCredentials(username: input.username, password: password)

        let trialSource = VidpickSource(configuration: configuration) {
            credentials
        }
        let loadedItems = try await fetchAllItems(from: trialSource)
        let remoteReviewSnapshot = (try? await trialSource.fetchReviewSnapshot())
            ?? VidpickReviewSnapshot(retention: [:], favorites: [])
        let profile = VidpickSavedProfile(
            serverAddress: configuration.baseURL.absoluteString,
            username: input.username,
            folderPath: configuration.folderPath,
            recursive: configuration.recursive
        )
        let reviewSnapshot = mergedReviewSnapshot(
            remote: remoteReviewSnapshot,
            local: VidpickLocalReviewStore.load(for: profile)
        )

        if !input.password.isEmpty {
            try VidpickCredentialStore.save(password: input.password, account: account)
        }
        VidpickProfileStore.save(profile)

        cachedVidpickCredentials = (account, credentials)
        vidpickSource = trialSource
        vidpickItems = loadedItems
        vidpickReviewSnapshot = reviewSnapshot
        vidpickStatus = .connected
        enterVidpick()
    }

    func restoreSavedVidpickIfNeeded() async {
        guard !hasAttemptedVidpickRestore else { return }
        hasAttemptedVidpickRestore = true
        guard let saved = VidpickProfileStore.load() else {
            vidpickStatus = .notConfigured
            return
        }

        vidpickStatus = .restoring
        do {
            try await connectVidpick(
                VidpickConnectionInput(
                    serverAddress: saved.serverAddress,
                    username: saved.username,
                    password: "",
                    folderPath: saved.folderPath,
                    recursive: saved.recursive
                )
            )
        } catch {
            vidpickStatus = .needsAttention
            if source == nil {
                message = "Vidpick 自动连接失败，请重新连接。"
            }
        }
    }

    func enterVidpick() {
        guard let vidpickSource, vidpickStatus == .connected else { return }
        source = vidpickSource
        isBrowsingVidpick = true
        sourceName = "Vidpick"
        sourceDetail = VidpickProfileStore.load()?.folderPath ?? "/"
        sourceSystemImage = "network"
        items = vidpickItems
        retentionByReference = Dictionary(
            uniqueKeysWithValues: vidpickReviewSnapshot.retention.map {
                (MediaReference(sourceID: vidpickSource.descriptor.id, itemID: $0.key), $0.value)
            }
        )
        favoriteReferences = Set(
            vidpickReviewSnapshot.favorites.map {
                MediaReference(sourceID: vidpickSource.descriptor.id, itemID: $0)
            }
        )
        message = vidpickItems.isEmpty
            ? "Vidpick 目录中没有发现视频。"
            : "Vidpick 已连接，载入 \(vidpickItems.count) 项。"
    }

    var pendingDeletionItems: [MediaItem] {
        items.filter { retentionByReference[$0.reference] == .reviewForDeletion }
    }

    var reviewedItems: [MediaItem] {
        items.filter { item in
            retentionByReference[item.reference] == .reviewForDeletion
                || favoriteReferences.contains(item.reference)
        }
    }

    var favoriteCount: Int {
        items.count { favoriteReferences.contains($0.reference) }
    }

    var canDeletePermanently: Bool {
        source?.descriptor.capabilities.contains(.permanentDeletion) == true
    }

    func applyReviewChoice(_ choice: MediaReviewChoice, to item: MediaItem) async -> Bool {
        guard let source, source.descriptor.id == item.reference.sourceID else {
            message = "当前媒体来源已经改变，请重新操作。"
            return false
        }

        let isRemovingDeletion = choice == .reviewForDeletion
            && retentionByReference[item.reference] == .reviewForDeletion
        let action: MediaAction
        switch choice {
        case .favorite:
            action = .setFavorite(!favoriteReferences.contains(item.reference))
        case .reviewForDeletion:
            action = isRemovingDeletion ? .restoreFromStagedDeletion : .stageDeletion
        }

        switch choice {
        case .favorite:
            if favoriteReferences.contains(item.reference) {
                favoriteReferences.remove(item.reference)
                message = "已取消喜欢“\(item.title)”。"
            } else {
                favoriteReferences.insert(item.reference)
                message = "已加入喜欢“\(item.title)”。"
            }
        case .reviewForDeletion:
            if isRemovingDeletion {
                retentionByReference[item.reference] = .undecided
                message = "已从待删除清单撤回“\(item.title)”。"
            } else {
                retentionByReference[item.reference] = .reviewForDeletion
                message = "已将“\(item.title)”加入待删除，删除前仍可撤销。"
            }
        }
        updateVidpickReviewSnapshotIfNeeded()

        let capabilities = source.descriptor.capabilities
        let shouldSynchronize = switch choice {
        case .favorite:
            capabilities.contains(.favorite)
        case .reviewForDeletion:
            capabilities.contains(.stagedDeletion)
        }
        if shouldSynchronize {
            do {
                try await source.perform(action, on: item.reference.itemID)
            } catch {
                message = "评选已保存在 SwipeFlow；Vidpick 状态同步暂时失败。"
            }
        }
        return true
    }

    func restoreFromDeletion(_ item: MediaItem) async {
        guard let source, source.descriptor.id == item.reference.sourceID else { return }
        retentionByReference[item.reference] = .undecided
        updateVidpickReviewSnapshotIfNeeded()
        message = "已从待删除清单撤回“\(item.title)”。"
        if source.descriptor.capabilities.contains(.stagedDeletion) {
            do {
                try await source.perform(.restoreFromStagedDeletion, on: item.reference.itemID)
            } catch {
                message = "已在 SwipeFlow 中撤回；Vidpick 状态同步暂时失败。"
            }
        }
    }

    func permanentlyDeletePendingItems() async -> Bool {
        guard let source, canDeletePermanently else {
            message = "当前来源不支持直接删除；待删除清单仍保留在本机。"
            return false
        }
        let deletingItems = pendingDeletionItems
        guard !deletingItems.isEmpty else { return true }

        isReviewActionRunning = true
        defer { isReviewActionRunning = false }
        do {
            try await source.perform(
                .deletePermanently,
                on: deletingItems.map(\.reference.itemID)
            )
            let deletedReferences = Set(deletingItems.map(\.reference))
            items.removeAll { deletedReferences.contains($0.reference) }
            retentionByReference = retentionByReference.filter {
                !deletedReferences.contains($0.key)
            }
            favoriteReferences.subtract(deletedReferences)
            if isBrowsingVidpick {
                vidpickItems.removeAll { deletedReferences.contains($0.reference) }
                updateVidpickReviewSnapshotIfNeeded()
            }
            message = "已删除 \(deletingItems.count) 个视频。"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func updateVidpickReviewSnapshotIfNeeded() {
        guard let vidpickSource, isBrowsingVidpick else { return }
        let sourceID = vidpickSource.descriptor.id
        vidpickReviewSnapshot = VidpickReviewSnapshot(
            retention: Dictionary(
                uniqueKeysWithValues: retentionByReference.compactMap { entry in
                    entry.key.sourceID == sourceID ? (entry.key.itemID, entry.value) : nil
                }
            ),
            favorites: Set(
                favoriteReferences.compactMap {
                    $0.sourceID == sourceID ? $0.itemID : nil
                }
            )
        )
        if let profile = VidpickProfileStore.load() {
            VidpickLocalReviewStore.save(
                VidpickLocalReviewState(
                    profile: profile,
                    retention: Dictionary(
                        uniqueKeysWithValues: vidpickReviewSnapshot.retention.map {
                            ($0.key.rawValue, $0.value == .reviewForDeletion ? "delete" : "clear")
                        }
                    ),
                    favorites: vidpickReviewSnapshot.favorites.map(\.rawValue)
                )
            )
        }
    }

    private func mergedReviewSnapshot(
        remote: VidpickReviewSnapshot,
        local: VidpickLocalReviewState?
    ) -> VidpickReviewSnapshot {
        var retention = remote.retention.filter { $0.value == .reviewForDeletion }
        guard let local else {
            return VidpickReviewSnapshot(
                retention: retention,
                favorites: remote.favorites
            )
        }
        for (path, value) in local.retention {
            switch value {
            case "delete":
                retention[MediaItemID(rawValue: path)] = .reviewForDeletion
            case "clear":
                retention[MediaItemID(rawValue: path)] = .undecided
            default:
                continue
            }
        }
        return VidpickReviewSnapshot(
            retention: retention,
            favorites: remote.favorites.union(
                local.favorites.map { MediaItemID(rawValue: $0) }
            )
        )
    }

    /// Loads every page exposed by a connector so filtering and locally saved
    /// review decisions are not limited to whichever 200 items happen to be in
    /// the first page after a reconnect.
    private func fetchAllItems(from source: any MediaSource) async throws -> [MediaItem] {
        var loadedItems: [MediaItem] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        while true {
            let page = try await source.fetchPage(
                MediaPageRequest(cursor: cursor, pageSize: 200)
            )
            loadedItems.append(contentsOf: page.items)

            guard let nextCursor = page.nextCursor,
                  seenCursors.insert(nextCursor).inserted else {
                return loadedItems
            }
            cursor = nextCursor
        }
    }
}

struct SourceBrowserView: View {
    @StateObject private var model = SourceBrowserModel()
    @State private var selectingKind: SourceKind?
    @State private var showingFolderImporter = false
    @State private var showingVidpickConnection = false
    @State private var showingDeleteReview = false
    @State private var showingReviewOverview = false
    @State private var showingDirectorySelection = false
    @State private var filterText = ""
    @State private var selectedDirectory = "/"
    @State private var isFavoritePlaylistActive = false
    @State private var isShuffleEnabled = false
    @State private var shuffledReferences: [MediaReference] = []

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if let appIcon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SwipeFlow")
                            .font(.title.bold())
                        Text("macOS 视频播放器")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("当前来源") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.sourceSystemImage)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.sourceName)
                                .font(.headline)
                                .lineLimit(1)
                            if let sourceDetail = model.sourceDetail {
                                Text(sourceDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .help(sourceDetail)
                            } else {
                                Text("请从下方选择一个目录或进入 Vidpick")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("切换来源")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    sourceButton(for: .localVideo)
                    sourceButton(for: .strm)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("播放目录")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        showingDirectorySelection = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                            Text(directoryDisplayName(selectedDirectory))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.items.isEmpty)
                    .help(selectedDirectory == "/" ? "全部目录" : selectedDirectory)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("播放列表")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        playFavoritesShuffled()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("随机播放我的喜欢")
                                    .font(.callout.weight(.semibold))
                                Text("\(model.favoriteCount) 个视频")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: isFavoritePlaylistActive ? "checkmark" : "shuffle")
                                .foregroundStyle(isFavoritePlaylistActive ? .yellow : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(
                            isFavoritePlaylistActive
                                ? Color.yellow.opacity(0.14)
                                : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isFavoritePlaylistActive
                                        ? Color.yellow.opacity(0.45)
                                        : Color.secondary.opacity(0.16),
                                    lineWidth: 0.75
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.favoriteCount == 0)

                    if isFavoritePlaylistActive {
                        Button("返回全部视频") {
                            isFavoritePlaylistActive = false
                            filterText = ""
                            selectedDirectory = "/"
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("播放选项")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("筛选标题或文件名", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.items.isEmpty)

                    HStack {
                        Label("随机播放", systemImage: "shuffle")
                        Spacer()
                        Toggle("随机播放", isOn: $isShuffleEnabled)
                            .labelsHidden()
                            .disabled(model.items.count < 2)
                    }

                    HStack {
                        Text("显示 \(displayedItems.count) / \(playbackScopeCount) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isShuffleEnabled {
                            Button("重新随机") {
                                reshuffle()
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                        }
                    }
                }

                GroupBox("评选进度") {
                    VStack(spacing: 9) {
                        reviewCountRow("喜欢", count: model.favoriteCount, color: .yellow)
                        reviewCountRow(
                            "待删除",
                            count: model.pendingDeletionItems.count,
                            color: .red
                        )

                        Button {
                            showingReviewOverview = true
                        } label: {
                            Label("查看评选详情", systemImage: "list.bullet.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.reviewedItems.isEmpty)

                        Button {
                            showingDeleteReview = true
                        } label: {
                            Label("复核待删除清单", systemImage: "trash.slash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.pendingDeletionItems.isEmpty)
                    }
                    .padding(.vertical, 3)
                }

                Divider()

                switch model.vidpickStatus {
                case .notConfigured:
                    Button("连接 Vidpick") {
                        showingVidpickConnection = true
                    }
                case .restoring:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在恢复 Vidpick…")
                            .foregroundStyle(.secondary)
                    }
                case .connected:
                    Label("Vidpick 已连接", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Button("进入 Vidpick") {
                        model.enterVidpick()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Vidpick 连接设置…") {
                        showingVidpickConnection = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                case .needsAttention:
                    Label("Vidpick 需要重新连接", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Button("重新连接 Vidpick") {
                        showingVidpickConnection = true
                    }
                }

                Spacer()
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if model.items.isEmpty {
                ContentUnavailableView(
                    "暂无媒体",
                    systemImage: "play.rectangle",
                    description: Text("连接目录后，媒体条目会显示在这里。")
                )
            } else if displayedItems.isEmpty {
                ContentUnavailableView {
                    Label(
                        isFavoritePlaylistActive ? "还没有可播放的喜欢视频" : "没有匹配的视频",
                        systemImage: isFavoritePlaylistActive
                            ? "heart.slash"
                            : "line.3.horizontal.decrease.circle"
                    )
                } description: {
                    if isFavoritePlaylistActive {
                        Text("退出喜欢播放列表后可以继续浏览全部视频。")
                    } else {
                        Text("没有标题或文件名符合“\(filterText)”的媒体。")
                    }
                } actions: {
                    Button(isFavoritePlaylistActive ? "返回全部视频" : "清除筛选并显示全部目录") {
                        isFavoritePlaylistActive = false
                        filterText = ""
                        selectedDirectory = "/"
                    }
                }
            } else {
                VerticalFeedView(
                    items: displayedItems,
                    retentionByReference: model.retentionByReference,
                    favoriteReferences: model.favoriteReferences,
                    resolve: { reference in
                        try await model.resolvePlayback(for: reference)
                    },
                    review: { choice, item in
                        await model.applyReviewChoice(choice, to: item)
                    }
                )
                .id(displayedItems.map(\.reference))
            }
        }
        .fileImporter(
            isPresented: $showingFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            let kind = selectingKind
            selectingKind = nil
            guard let kind else { return }
            if case let .success(urls) = result, let url = urls.first {
                model.open(url, as: kind)
            } else if case let .failure(error) = result {
                model.message = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingVidpickConnection) {
            VidpickConnectionView { input in
                try await model.connectVidpick(input)
            }
        }
        .sheet(isPresented: $showingDeleteReview) {
            DeletionReviewView(
                items: model.pendingDeletionItems,
                canDeletePermanently: model.canDeletePermanently,
                isDeleting: model.isReviewActionRunning,
                restore: { item in
                    await model.restoreFromDeletion(item)
                },
                deleteAll: {
                    await model.permanentlyDeletePendingItems()
                }
            )
        }
        .sheet(isPresented: $showingReviewOverview) {
            ReviewOverviewView(
                items: model.reviewedItems,
                retentionByReference: model.retentionByReference,
                favoriteReferences: model.favoriteReferences
            )
        }
        .sheet(isPresented: $showingDirectorySelection) {
            DirectorySelectionView(
                directories: directoryOptions,
                selection: Binding(
                    get: { selectedDirectory },
                    set: { directory in
                        selectedDirectory = directory
                        isFavoritePlaylistActive = false
                    }
                )
            )
        }
        .task {
            await model.restoreSavedVidpickIfNeeded()
        }
        .onChange(of: isShuffleEnabled) { _, enabled in
            if enabled {
                reshuffle()
            } else {
                shuffledReferences = []
            }
        }
        .onChange(of: model.items.map(\.reference)) { _, references in
            if !directoryOptions.contains(where: { $0.path == selectedDirectory }) {
                selectedDirectory = "/"
            }
            if isShuffleEnabled {
                shuffledReferences = references.shuffled()
            } else {
                shuffledReferences = []
            }
        }
        .onChange(of: model.favoriteReferences) { _, favorites in
            if isFavoritePlaylistActive {
                if favorites.isEmpty {
                    isFavoritePlaylistActive = false
                } else {
                    shuffledReferences = favorites.shuffled()
                }
            }
        }
    }

    private var filteredItems: [MediaItem] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = isFavoritePlaylistActive
            ? model.items.filter { model.favoriteReferences.contains($0.reference) }
            : directoryFilteredItems
        return candidates.filter { item in
            guard !query.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(query)
                || (item.detailText?.localizedCaseInsensitiveContains(query) ?? false)
                || (item.fileExtension?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var directoryFilteredItems: [MediaItem] {
        guard selectedDirectory != "/" else { return model.items }
        let prefix = selectedDirectory.hasSuffix("/")
            ? selectedDirectory
            : selectedDirectory + "/"
        return model.items.filter { item in
            let directory = parentDirectory(of: item)
            return directory == selectedDirectory || directory.hasPrefix(prefix)
        }
    }

    private var directoryOptions: [PlaybackDirectory] {
        var counts: [String: Int] = ["/": model.items.count]
        for item in model.items {
            var directory = parentDirectory(of: item)
            while directory != "/" {
                counts[directory, default: 0] += 1
                let parent = (directory as NSString).deletingLastPathComponent
                directory = normalizedDirectory(parent)
            }
        }
        return counts.map { PlaybackDirectory(path: $0.key, itemCount: $0.value) }
            .sorted { left, right in
                if left.path == "/" { return true }
                if right.path == "/" { return false }
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
    }

    private var displayedItems: [MediaItem] {
        guard isShuffleEnabled else { return filteredItems }
        let positions = Dictionary(
            uniqueKeysWithValues: shuffledReferences.enumerated().map { ($0.element, $0.offset) }
        )
        return filteredItems.sorted {
            (positions[$0.reference] ?? .max) < (positions[$1.reference] ?? .max)
        }
    }

    private var playbackScopeCount: Int {
        isFavoritePlaylistActive ? model.favoriteCount : model.items.count
    }

    @ViewBuilder
    private func sourceButton(for kind: SourceKind) -> some View {
        Button {
            selectingKind = kind
            showingFolderImporter = true
        } label: {
            Label("选择\(kind.title)", systemImage: kind.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private func reshuffle() {
        shuffledReferences = model.items.map(\.reference).shuffled()
    }

    private func playFavoritesShuffled() {
        guard model.favoriteCount > 0 else { return }
        isFavoritePlaylistActive = true
        selectedDirectory = "/"
        filterText = ""
        isShuffleEnabled = true
        shuffledReferences = model.favoriteReferences.shuffled()
    }

    private func parentDirectory(of item: MediaItem) -> String {
        let path = item.reference.itemID.rawValue.replacingOccurrences(of: "\\", with: "/")
        return normalizedDirectory((path as NSString).deletingLastPathComponent)
    }

    private func normalizedDirectory(_ directory: String) -> String {
        guard !directory.isEmpty, directory != ".", directory != "/" else { return "/" }
        return directory.hasPrefix("/") ? directory : "/" + directory
    }

    private func directoryDisplayName(_ directory: String) -> String {
        directory == "/" ? "全部目录" : (directory as NSString).lastPathComponent
    }

    private func reviewCountRow(_ title: String, count: Int, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
            Spacer()
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct PlaybackDirectory: Identifiable, Hashable {
    let path: String
    let itemCount: Int

    var id: String { path }
}

private enum ReviewOverviewFilter: String, CaseIterable, Identifiable {
    case all
    case favorite
    case pendingDeletion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .favorite: "喜欢"
        case .pendingDeletion: "待删除"
        }
    }
}

private struct ReviewOverviewView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [MediaItem]
    let retentionByReference: [MediaReference: RetentionState]
    let favoriteReferences: Set<MediaReference>

    @State private var filter: ReviewOverviewFilter = .all
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("评选详情")
                        .font(.title2.bold())
                    Text("本机已记录 \(items.count) 个视频的评选状态。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(22)

            HStack(spacing: 12) {
                Picker("状态", selection: $filter) {
                    ForEach(ReviewOverviewFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                TextField("搜索文件名或路径", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            Divider()

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    "没有匹配的评选记录",
                    systemImage: "list.bullet.clipboard",
                    description: Text("可以切换状态或清除搜索文字。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.reference.itemID.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.reference.itemID.rawValue)
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            if favoriteReferences.contains(item.reference) {
                                statusBadge("喜欢", systemImage: "heart.fill", color: .yellow)
                            }
                            if retentionByReference[item.reference] == .reviewForDeletion {
                                statusBadge("待删除", systemImage: "trash", color: .red)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 580)
    }

    private var filteredItems: [MediaItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            let matchesFilter = switch filter {
            case .all:
                true
            case .favorite:
                favoriteReferences.contains(item.reference)
            case .pendingDeletion:
                retentionByReference[item.reference] == .reviewForDeletion
            }
            guard matchesFilter else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(trimmedQuery)
                || item.reference.itemID.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func statusBadge(
        _ title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct DirectorySelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let directories: [PlaybackDirectory]
    @Binding var selection: String
    @State private var browsingPath = "/"
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择播放目录")
                        .font(.title2.bold())
                    Text("逐级进入目录，选择后会播放该目录及其下级目录中的视频。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding(22)

            HStack(spacing: 10) {
                Button {
                    browsingPath = parentPath(of: browsingPath)
                    query = ""
                } label: {
                    Label("上一级", systemImage: "chevron.left")
                }
                .disabled(browsingPath == "/")

                VStack(alignment: .leading, spacing: 2) {
                    Text("当前位置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(browsingPath == "/" ? "全部目录" : browsingPath)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(browsingPath)
                }

                Spacer()

                TextField("筛选本级目录", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            Divider()

            if filteredChildren.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "没有下级目录" : "本级没有匹配的目录",
                    systemImage: "folder",
                    description: Text("可以选择当前位置，或返回上一级。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredChildren) { directory in
                    Button {
                        browsingPath = directory.path
                        query = ""
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text((directory.path as NSString).lastPathComponent)
                                    .font(.headline)
                                Text("包含 \(directory.itemCount) 个视频")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if directory.path == selection {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                let currentCount = directories.first { $0.path == browsingPath }?.itemCount ?? 0
                Text("当前位置包含 \(currentCount) 个视频")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("选择当前位置") {
                    selection = browsingPath
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentCount == 0)
            }
            .padding(18)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            browsingPath = directories.contains(where: { $0.path == selection })
                ? selection
                : "/"
        }
    }

    private var filteredChildren: [PlaybackDirectory] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return directories.filter { directory in
            guard directory.path != "/",
                  parentPath(of: directory.path) == browsingPath else {
                return false
            }
            return trimmedQuery.isEmpty
                || (directory.path as NSString).lastPathComponent
                    .localizedCaseInsensitiveContains(trimmedQuery)
        }
        .sorted {
            ($0.path as NSString).lastPathComponent.localizedStandardCompare(
                ($1.path as NSString).lastPathComponent
            ) == .orderedAscending
        }
    }

    private func parentPath(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? "/" : parent
    }
}

private struct DeletionReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [MediaItem]
    let canDeletePermanently: Bool
    let isDeleting: Bool
    let restore: @MainActor (MediaItem) async -> Void
    let deleteAll: @MainActor () async -> Bool

    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("复核待删除清单")
                        .font(.title2.bold())
                    Text("共 \(items.count) 个视频；在最终确认前可以逐项撤回。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .disabled(isDeleting)
            }
            .padding(22)

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "没有待删除的视频",
                    systemImage: "checkmark.circle",
                    description: Text("可以返回播放器继续评选。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.reference.itemID.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("撤回") {
                            Task { await restore(item) }
                        }
                        .disabled(isDeleting)
                    }
                    .padding(.vertical, 5)
                }
            }

            Divider()

            HStack {
                if canDeletePermanently {
                    Label(
                        "永久删除会作用于 Vidpick 后端存储。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Label(
                        "当前来源仅保存评选清单，不会直接删除文件。",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if canDeletePermanently {
                    Button("永久删除 \(items.count) 个视频", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .disabled(items.isEmpty || isDeleting)
                }
            }
            .padding(22)
        }
        .frame(minWidth: 720, minHeight: 520)
        .confirmationDialog(
            "确认永久删除这 \(items.count) 个视频？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("我已逐项核对，确认永久删除", role: .destructive) {
                Task {
                    if await deleteAll() {
                        dismiss()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会请求 Vidpick 逐项核对并删除原文件，是否可恢复取决于后端存储。")
        }
    }
}

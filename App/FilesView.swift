import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import QuickLookThumbnailing
import ImageIO
import LunaSyncPhotoKit
import LunaSyncCore

struct FilePreview: Identifiable {
    let id = UUID()
    let urls: [URL]
    let index: Int
    var isMedia = true
}

@MainActor
final class DiskBrowserModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var notice: String?
    @Published var needsReconnect = false
    @Published var checking = false
    @Published private(set) var deleting = false
    private var access: DirectoryAccess?
    // One metadata snapshot, in memory only. Revalidate against the drive on
    // every visit; switching tabs need not hide the previous first screen.
    struct Snapshot {
        let directory: URL
        let entries: [DiskEntry]
        let index: DiskDirectoryIndex
        let name: String
        let rootName: String
    }
    var rootSnapshot: Snapshot?
    private var selectionRevision = 0
    private var selecting = false
    var retainedDirectoryAccess: DirectoryAccess? { access }

    func refreshAvailability() async {
        guard !checking, !selecting else { return }
        checking = true
        defer { checking = false }
        let revision = selectionRevision
        if let rootURL {
            let readable = await Task.detached(priority: .utility) {
                FileManager.default.isReadableFile(atPath: rootURL.path)
            }.value
            guard revision == selectionRevision else { return }
            if readable { needsReconnect = false; return }
            needsReconnect = true
            rootSnapshot = nil
        }
        guard let bookmark = UserDefaults.standard.data(forKey: "browserDirectoryBookmark") else { return }
        do {
            let (scope, refreshedBookmark) = try await Task.detached(priority: .utility) {
                let scope = try DirectoryAccess(bookmark: bookmark)
                return (scope, try scope.bookmark())
            }.value
            guard revision == selectionRevision else { return }
            open(scope, bookmark: refreshedBookmark)
        } catch { if revision == selectionRevision { needsReconnect = true } }
    }

    func select(_ url: URL) {
        selectionRevision += 1
        let revision = selectionRevision
        selecting = true
        Task {
            defer { if revision == selectionRevision { selecting = false } }
            do {
                let (scope, bookmark) = try await Task.detached(priority: .userInitiated) {
                    let scope = try DirectoryAccess(url: url)
                    return (scope, try scope.bookmark())
                }.value
                guard revision == selectionRevision else { return }
                open(scope, bookmark: bookmark)
            } catch { if revision == selectionRevision { notice = error.localizedDescription } }
        }
    }

    func delete(_ entry: DiskEntry, in directory: URL) async throws {
        guard !deleting, let retainedAccess = access else { throw BackupFailure.permissionDenied }
        rootSnapshot = nil
        deleting = true
        defer { deleting = false }
        try await Task.detached(priority: .userInitiated) {
            try withExtendedLifetime(retainedAccess) {
                try DiskDirectoryIndex.delete(entry.url, in: directory)
            }
        }.value
    }

    private func open(_ scope: DirectoryAccess, bookmark: Data) {
        rootSnapshot = nil
        access = scope
        rootURL = scope.url
        needsReconnect = false
        UserDefaults.standard.set(bookmark, forKey: "browserDirectoryBookmark")
    }
}

struct DiskBrowserView: View {
    @ObservedObject var model: DiskBrowserModel
    @Binding var showingPicker: Bool
    var deletionAllowed = true

    var body: some View {
        NavigationStack {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--review-large-directory") {
                    DiskDirectoryView(url: FileManager.default.temporaryDirectory.appendingPathComponent("Directory Stress Test"),
                                      rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("Directory Stress Test"), deletionAllowed: false)
                } else {
                    browserContent
                }
                #else
                browserContent
                #endif
            }.toolbar(.hidden, for: .navigationBar)
        }
        .environmentObject(model)
        .sheet(isPresented: $showingPicker) { DirectoryPicker(initialURL: model.rootURL, purpose: .browse) { model.select($0) } }
        .alert(L10n.tr("copy.bb05dd14"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(L10n.tr("copy.96547fdd")) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    @ViewBuilder private var browserContent: some View {
        if let root = model.rootURL, !model.needsReconnect {
            DiskDirectoryView(url: root, rootURL: root, changeLocation: { showingPicker = true }, deletionAllowed: deletionAllowed)
        } else {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LunaHeader(title: L10n.tr("copy.bb05dd14"), symbol: "folder", action: { showingPicker = true })
                            .padding(.bottom, 28)
                        PageIntro(title: L10n.tr("ui.files.empty.title"), detail: L10n.tr("ui.files.empty.body"))
                        DriveIllustration().padding(.top, 38).padding(.bottom, 24)
                        Text(L10n.tr(model.needsReconnect ? "ui.files.disconnected" : "ui.files.noFolder"))
                            .lunaFont(18, weight: .semibold).frame(maxWidth: .infinity)
                        Text(L10n.tr(model.needsReconnect ? "ui.files.reconnect" : "ui.files.choose"))
                            .lunaFont(13).foregroundStyle(LunaColor.muted).lineSpacing(4)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 10)
                        if model.needsReconnect {
                            Button(L10n.tr("destination.retry")) { Task { await model.refreshAvailability() } }
                                .lunaFont(13, weight: .medium).frame(maxWidth: .infinity).frame(minHeight: 44).disabled(model.checking)
                        }
                        Spacer(minLength: 24)
                    }.padding(.horizontal, LunaLayout.pageInset).padding(.top, 12).padding(.bottom, 24)
                        .frame(minHeight: geometry.size.height)
                }.background(LunaColor.paper)
            }

        }
    }
}

struct DiskDirectoryView: View {
    enum ViewMode: String, CaseIterable { case grid, list }
    enum MediaFilter: CaseIterable {
        case all, photos, videos
        var title: String {
            switch self {
            case .all: L10n.tr("files.filter.all")
            case .photos: L10n.tr("copy.de93c953")
            case .videos: L10n.tr("copy.5e6f06f8")
            }
        }
    }
    let url: URL
    let rootURL: URL
    var changeLocation: (() -> Void)? = nil
    var deletionAllowed = true
    @EnvironmentObject private var browser: DiskBrowserModel
    @State private var pendingDeletion: DiskEntry?
    @State private var deletionError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DiskEntry] = []
    @State private var index: DiskDirectoryIndex?
    @State private var loading = true
    @State private var error: String?
    @State private var preview: FilePreview?
    #if DEBUG
    @State private var openedReviewViewer = false
    #endif
    @State private var reloadID = UUID()
    @State private var viewMode: ViewMode = .grid
    @State private var filter: MediaFilter = .all
    @State private var newestFirst = true
    @State private var showingSearch = false
    @State private var search = ""
    @State private var directoryTitle = ""
    @State private var rootTitle = ""
    @AppStorage("diskGridColumns") private var gridColumns = 3

    private struct Query: Equatable {
        let directory: URL
        let filter: MediaFilter
        let search: String
        let newestFirst: Bool
        let revision: UUID
    }
    private var query: Query { Query(directory: url, filter: filter, search: search, newestFirst: newestFirst, revision: reloadID) }
    private var visibleEntries: [DiskEntry] { index?.entries ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LunaHeader(title: L10n.tr("copy.bb05dd14"), back: url == rootURL ? nil : { dismiss() },
                           symbol: changeLocation == nil ? "magnifyingglass" : "folder", action: {
                               if let changeLocation { changeLocation() } else { showingSearch.toggle() }
                           }).padding(.bottom, 18)
                Text(folderTitle).lunaFont(16, weight: .semibold).lineLimit(1).truncationMode(.middle)
                if relativeLocation != folderTitle && !relativeLocation.isEmpty {
                    Text(relativeLocation).lunaFont(12).foregroundStyle(LunaColor.muted)
                        .lineLimit(2).truncationMode(.middle).padding(.top, 6)
                }
                if showingSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(LunaColor.muted)
                        TextField(L10n.tr("files.search"), text: $search).lunaFont(14).submitLabel(.search)
                        Button { search = ""; showingSearch = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(LunaColor.muted).frame(width: 44, height: 44)
                        }.accessibilityLabel(L10n.tr("directory.cancel"))
                    }.padding(.leading, 12).background(LunaColor.panel, in: RoundedRectangle(cornerRadius: 14)).padding(.top, 14)
                }
                HStack(spacing: 4) {
                    ForEach(MediaFilter.allCases, id: \.self) { value in
                        Button { filter = value } label: {
                            Text(value.title).lunaFont(12, weight: filter == value ? .semibold : .regular)
                                .foregroundStyle(filter == value ? LunaColor.accent : LunaColor.muted)
                                .frame(maxWidth: .infinity).frame(minHeight: 44)
                                .background(filter == value ? LunaColor.surface : .clear, in: RoundedRectangle(cornerRadius: 13))
                        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                    }
                }.padding(4).background(LunaColor.subtlePanel, in: RoundedRectangle(cornerRadius: 17)).padding(.top, 20)
                HStack(spacing: 0) {
                    Text(L10n.format("design.files.count", visibleEntries.count.formatted()))
                        .lunaFont(12, weight: .medium).foregroundStyle(LunaColor.muted)
                    Spacer(minLength: 0)
                    Button { showingSearch.toggle() } label: {
                        Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                    }.accessibilityLabel(L10n.tr("files.search"))
                    if viewMode == .grid {
                        Button { gridColumns = gridColumns == 3 ? 4 : (gridColumns == 4 ? 5 : 3) } label: {
                            Image(systemName: "square.grid.3x3").frame(width: 44, height: 44)
                        }.accessibilityLabel(L10n.tr("files.grid.density"))
                    }
                    Menu {
                        Button(L10n.tr("design.files.sort.date")) { newestFirst = true }
                        Button(L10n.tr("design.files.sort.name")) { newestFirst = false }
                        Picker(L10n.tr("copy.2edb8665"), selection: $viewMode) {
                            Text(L10n.tr("copy.3a20e040")).tag(ViewMode.grid)
                            Text(L10n.tr("copy.e4560cda")).tag(ViewMode.list)
                        }
                        Button(L10n.tr("copy.8b9fe232")) { reloadID = UUID() }
                        if let changeLocation { Button(L10n.tr("copy.8ec4cba0"), action: changeLocation) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }.accessibilityLabel(L10n.tr("ui.files.options"))
                }.lunaFont(16).foregroundStyle(LunaColor.muted).padding(.top, 8).padding(.bottom, 4)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 70)
                } else if let error {
                    Text(error).lunaFont(12).foregroundStyle(LunaColor.muted).padding(.vertical, 30)
                } else if visibleEntries.isEmpty {
                    Text(L10n.tr(entries.isEmpty ? "copy.24bacd93" : "files.empty.filter")).lunaFont(12)
                        .foregroundStyle(LunaColor.muted).frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if viewMode == .grid {
                    LazyVStack(spacing: 0) {
                        ForEach(index?.rows ?? []) { entry in
                            entryDestination(entry) { DiskEntryRow(entry: entry).padding(.vertical, 12) }
                            Divider()
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: (3...5).contains(gridColumns) ? gridColumns : 3), spacing: 6) {
                        ForEach(index?.media ?? []) { entry in
                            entryDestination(entry) { DiskEntryTile(entry: entry) }
                        }
                    }.padding(.top, !(index?.rows.isEmpty ?? true) ? 14 : 0)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            entryDestination(entry) { DiskEntryRow(entry: entry).padding(.vertical, 12) }
                            Divider()
                        }
                    }
                }
                Text(L10n.tr("design.files.footer")).lunaFont(10).foregroundStyle(LunaColor.muted.opacity(0.8))
                    .frame(maxWidth: .infinity).padding(.top, 15)
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
            .disabled(browser.deleting)
            .overlay {
                if browser.deleting {
                    ProgressView(L10n.tr("files.delete.progress"))
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert(L10n.tr("files.delete.title"), isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { entry in
                Button(L10n.tr("files.delete.action"), role: .destructive) {
                    Task { await delete(entry) }
                }.disabled(!deletionAllowed)
                Button(L10n.tr("directory.cancel"), role: .cancel) {}
            } message: { entry in
                Text(L10n.format(entry.isDirectory ? "files.delete.folder.message" : "files.delete.file.message", entry.name))
            }
            .alert(L10n.tr("files.delete.error"), isPresented: Binding(
                get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
            )) {
                Button(L10n.tr("copy.96547fdd")) { deletionError = nil }
            } message: { Text(deletionError ?? "") }
            .refreshable { await load() }
            .task(id: query) { await updateIndex() }
            #if DEBUG
            .task { await recordStressResponsiveness() }
            .onChange(of: index?.media.count) { _, count in
                guard !openedReviewViewer, ProcessInfo.processInfo.arguments.contains("--review-open-viewer"),
                      (count ?? 0) > 0, let index else { return }
                openedReviewViewer = true
                let movie = ProcessInfo.processInfo.arguments.contains("--review-viewer-video")
                let selected = index.mediaPreviewURLs.firstIndex { candidate in
                    let type = UTType(filenameExtension: candidate.pathExtension)
                    return movie ? type?.conforms(to: .movie) == true : type?.conforms(to: .image) == true
                } ?? 0
                preview = FilePreview(urls: index.mediaPreviewURLs, index: selected)
            }
            #endif
            .fullScreenCover(item: $preview) { selection in
                if selection.isMedia {
                    MediaViewer(urls: selection.urls, initialIndex: selection.index,
                                retainedAccess: browser.retainedDirectoryAccess, deletionAllowed: deletionAllowed,
                                onDelete: { target in
                        guard deletionAllowed, let entry = entries.first(where: { $0.url == target }) else {
                            throw BackupFailure.unavailable(L10n.tr("viewer.file.unavailable"))
                        }
                        try await browser.delete(entry, in: url)
                        reloadID = UUID()
                    }, onClose: { preview = nil })
                } else {
                    ArchivePreviewController(urls: selection.urls, initialIndex: selection.index) { preview = nil }.ignoresSafeArea()
                }
            }
    }

    private var folderTitle: String {
        let name = directoryTitle.isEmpty ? L10n.tr("copy.3419b5fd") : directoryTitle
        let parts = name.split(separator: "-")
        if parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
           parts[0].count == 4, (1...12).contains(month),
           let date = Calendar.current.date(from: DateComponents(year: year, month: month)) {
            return date.formatted(.dateTime.year().month(.wide))
        }
        return name.isEmpty ? L10n.tr("copy.3419b5fd") : name
    }

    private var relativeLocation: String {
        let root = rootURL.standardizedFileURL.path
        let current = url.standardizedFileURL.path
        guard current != root, current.hasPrefix(root + "/") else { return rootTitle }
        return rootTitle + "  ›  " + String(current.dropFirst(root.count + 1)).replacingOccurrences(of: "/", with: "  ›  ")
    }

    private func entryDestination<Label: View>(_ entry: DiskEntry, @ViewBuilder label: () -> Label) -> some View {
        entryLink(entry, label: label)
            .contextMenu {
                Button(L10n.tr("files.delete.action"), systemImage: "trash", role: .destructive) {
                    pendingDeletion = entry
                }.disabled(!deletionAllowed || browser.deleting)
            }
            .accessibilityAction(named: L10n.tr("files.delete.action")) {
                if deletionAllowed && !browser.deleting { pendingDeletion = entry }
            }
    }

    @ViewBuilder private func entryLink<Label: View>(_ entry: DiskEntry, @ViewBuilder label: () -> Label) -> some View {
        if entry.isDirectory {
            NavigationLink { DiskDirectoryView(url: entry.url, rootURL: rootURL, changeLocation: changeLocation, deletionAllowed: deletionAllowed) } label: { label() }.buttonStyle(.plain)
        } else {
            Button {
                guard let index else { return }
                if entry.isMedia {
                    preview = FilePreview(urls: index.mediaPreviewURLs, index: index.mediaPreviewIndices[entry.url] ?? 0)
                } else {
                    preview = FilePreview(urls: [entry.url], index: 0, isMedia: false)
                }
            } label: { label() }.buttonStyle(.plain)
        }
    }

    private func delete(_ entry: DiskEntry) async {
        guard deletionAllowed, !browser.deleting else { return }
        do {
            try await browser.delete(entry, in: url)
            reloadID = UUID()
        } catch {
            // A provider can fail after removing part of a folder; re-read even on failure.
            deletionError = error.localizedDescription
            reloadID = UUID()
        }
    }

    private func load() async {
        reloadID = UUID()
    }

    private func updateIndex() async {
        let current = query
        let canRestore = loadedDirectory == nil && url == rootURL && current.filter == .all
            && current.search.isEmpty && current.newestFirst
        if canRestore, let snapshot = browser.rootSnapshot, snapshot.directory == url {
            entries = snapshot.entries; index = snapshot.index
            directoryTitle = snapshot.name; rootTitle = snapshot.rootName
        }
        loading = index == nil; error = nil
        let directory = url
        let cachedEntries = entries
        let needsRead = loadedRevision != reloadID || loadedDirectory != directory
        let worker = Task.detached(priority: .userInitiated) {
            if !current.search.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
            let source = needsRead ? try Self.readDirectory(directory) : cachedEntries
            let filter: DiskDirectoryIndex.Filter = current.filter == .all ? .all : (current.filter == .photos ? .photos : .videos)
            return (source, DirectoryDisplayName.read(directory), DirectoryDisplayName.read(rootURL), try DiskDirectoryIndex(entries: source, filter: filter, search: current.search, newestFirst: current.newestFirst))
        }
        do {
            let (source, name, rootName, result) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard current == query else { return }
            directoryTitle = name; rootTitle = rootName
            entries = source; index = result; loadedRevision = current.revision; loadedDirectory = directory
            if directory == rootURL && current.filter == .all && current.search.isEmpty && current.newestFirst {
                browser.rootSnapshot = .init(directory: directory, entries: source, index: result, name: name, rootName: rootName)
            }
            loading = false
        } catch is CancellationError { }
        catch {
            guard current == query, !Task.isCancelled else { return }
            browser.rootSnapshot = nil
            entries = []; index = nil
            self.error = error.localizedDescription; loading = false
        }
    }

    @State private var loadedRevision: UUID?
    @State private var loadedDirectory: URL?

    nonisolated private static func readDirectory(_ url: URL) throws -> [DiskEntry] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--review-large-directory") {
            return (0..<50_000).map { value in
                DiskEntry(url: url.appendingPathComponent("IMG_\(value).jpg"), kind: .image,
                          modifiedAt: Date(timeIntervalSince1970: Double(value)))
            }
        }
        #endif
        return try DiskDirectoryIndex.read(url)
    }

    #if DEBUG
    @MainActor private func recordStressResponsiveness() async {
        guard ProcessInfo.processInfo.arguments.contains("--review-large-directory") else { return }
        let start = Date()
        var previous = start
        var longestGap: TimeInterval = 0
        var ticks = 0
        while Date().timeIntervalSince(start) < 6 {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            let now = Date()
            longestGap = max(longestGap, now.timeIntervalSince(previous))
            previous = now; ticks += 1
        }
        let result = "Synthetic directory UI: \(visibleEntries.count) entries; main task ticks: \(ticks); longest scheduling gap: \(longestGap)s. Placeholder thumbnails; excludes external-drive I/O and image decoding."
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DesignReview")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? result.write(to: folder.appendingPathComponent("disk-performance.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}

/// Only visible cells request thumbnails. Bound both USB I/O concurrency and
/// decoded-image memory; cancel requests as cells leave the screen.
@MainActor
final class DiskThumbnailLoader {
    static let shared = DiskThumbnailLoader()
    private let cache = NSCache<NSString, UIImage>()
    private struct Job {
        let request: QLThumbnailGenerator.Request
        let entry: DiskEntry
        let pixels: Int
        let key: NSString
        let continuation: CheckedContinuation<UIImage?, Never>
    }
    private var waiting: [UUID] = []
    private var jobs: [UUID: Job] = [:]
    private var active: Set<UUID> = []
    private var decoders: [UUID: Task<Void, Never>] = [:]
    private let limit = 4

    init() {
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 160
    }

    func image(for entry: DiskEntry, pixels: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(entry.url.absoluteString)|\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)|\(entry.size ?? 0)|\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: pixels, height: pixels),
                    scale: 1, representationTypes: entry.isMedia ? [.thumbnail] : [.thumbnail, .icon])
                jobs[id] = Job(request: request, entry: entry, pixels: pixels, key: key, continuation: continuation)
                waiting.append(id)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        waiting.removeAll { $0 == id }
        if let decoder = decoders[id] {
            // ImageIO is synchronous: keep its slot until it returns, so fast
            // scrolling cannot spawn an unbounded number of USB reads.
            decoder.cancel()
        } else if active.remove(id) != nil {
            QLThumbnailGenerator.shared.cancel(job.request)
        }
        job.continuation.resume(returning: nil)
        pump()
    }

    private func pump() {
        while active.count < limit, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let job = jobs[id] else { continue }
            active.insert(id)
            if job.entry.kind == .image {
                let url = job.entry.url
                let pixels = job.pixels
                decoders[id] = Task.detached(priority: .userInitiated) {
                    let image = Self.decodePhoto(url, pixels: pixels)
                    let cancelled = Task.isCancelled
                    await self.photoDecoded(image, id: id, cancelled: cancelled)
                }
            } else {
                generateQuickLook(id, job: job)
            }
        }
    }

    nonisolated private static func decodePhoto(_ url: URL, pixels: Int) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                !Task.isCancelled,
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary), !Task.isCancelled else { return nil }
            return UIImage(cgImage: image)
        }
    }

    private func photoDecoded(_ image: UIImage?, id: UUID, cancelled: Bool) {
        decoders.removeValue(forKey: id)
        guard let job = jobs[id], !cancelled else {
            active.remove(id)
            pump()
            return
        }
        if let image {
            finish(image, id: id)
        } else {
            // Preserve provider/special-format support if ImageIO cannot read it.
            generateQuickLook(id, job: job)
        }
    }

    private func generateQuickLook(_ id: UUID, job: Job) {
        QLThumbnailGenerator.shared.generateBestRepresentation(for: job.request) { representation, _ in
            Task { @MainActor in self.finish(representation?.uiImage, id: id) }
        }
    }

    private func finish(_ image: UIImage?, id: UUID) {
        active.remove(id)
        if let job = jobs.removeValue(forKey: id) {
            if let image {
                let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * 4)
                cache.setObject(image, forKey: job.key, cost: cost)
            }
            job.continuation.resume(returning: image)
        }
        pump()
    }
}

/// Identity includes metadata and size, so refreshes and grid-density changes reload the right image.
private struct DiskThumbnailIdentity: Hashable {
    let url: URL
    let modifiedAt: Date?
    let size: Int64?
    let pixels: Int
    let visible: Bool
    init(_ entry: DiskEntry, pixels: Int, visible: Bool) {
        url = entry.url; modifiedAt = entry.modifiedAt; size = entry.size
        self.pixels = pixels; self.visible = visible
    }
}

struct DiskEntryTile: View {
    let entry: DiskEntry
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var isVisible = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit).overlay {
            GeometryReader { geometry in
                let target = geometry.size.width * scale
                let pixels = [128, 192, 256, 384, 512].first { CGFloat($0) >= target } ?? 512
                ZStack {
                    LunaColor.panel
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else { Image(systemName: "photo").lunaFont(24, weight: .light).foregroundStyle(LunaColor.muted) }
                }
                .task(id: DiskThumbnailIdentity(entry, pixels: pixels, visible: isVisible)) {
                    guard isVisible else { image = nil; return }
                    let thumbnail = await DiskThumbnailLoader.shared.image(for: entry, pixels: pixels)
                    guard !Task.isCancelled, isVisible else { return }
                    image = thumbnail
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if entry.kind == .video {
                    Image(systemName: "play.fill").lunaFont(10).foregroundStyle(.white).shadow(radius: 2).padding(7)
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isVisible = visible
                if !visible { image = nil }
            }
            .onDisappear { isVisible = false; image = nil }
            .accessibilityLabel(entry.url.lastPathComponent)
    }
}

struct DiskEntryRow: View {
    let entry: DiskEntry
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            if entry.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.title2).foregroundStyle(LunaColor.accent)
                    .frame(width: 48, height: 48)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: fileIcon)
                    .font(.title2).foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.url.lastPathComponent).lunaFont(12, weight: .medium).lineLimit(2)
                HStack(spacing: 8) {
                    if let size = entry.size, !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let date = entry.modifiedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .lunaFont(10).foregroundStyle(LunaColor.muted)
            }
        }
        .contentShape(Rectangle())
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
            if !visible { image = nil }
        }
        .onDisappear { isVisible = false; image = nil }
        .task(id: DiskThumbnailIdentity(entry, pixels: Int(48 * scale), visible: isVisible)) {
            guard isVisible, !entry.isDirectory else { image = nil; return }
            let thumbnail = await DiskThumbnailLoader.shared.image(for: entry, pixels: max(96, min(192, Int(48 * scale))))
            guard !Task.isCancelled, isVisible else { return }
            image = thumbnail
        }
    }

    private var fileIcon: String {
        guard let type = UTType(filenameExtension: entry.url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "video" }
        if type.conforms(to: .audio) { return "waveform" }
        return "doc"
    }
}

struct ArchivePreviewController: UIViewControllerRepresentable {
    let urls: [URL]
    let initialIndex: Int
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls, onClose: onClose) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = min(initialIndex, max(0, urls.count - 1))
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.close))
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        let onClose: () -> Void
        init(urls: [URL], onClose: @escaping () -> Void) { self.urls = urls; self.onClose = onClose }
        @objc func close() { onClose() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}

struct SystemDirectoryPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}


/// System selections commit immediately. Inside an authorized location, browsing
/// and choosing are separate actions; listing children never blocks confirmation.
struct DirectoryPicker: View {
    enum Purpose { case backup, browse }
    var initialURL: URL? = nil
    var purpose: Purpose = .backup
    var onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scope: DirectoryAccess?
    @State private var path: [URL] = []
    @State private var folders: [URL] = []
    @State private var resolvedTitle = ""
    @State private var showingSystem = false
    @State private var systemSelection: URL?
    @State private var showingName = false
    @State private var folderName = ""
    @State private var restoring = true
    @State private var connecting = false
    @State private var loadingFolders = false
    @State private var creating = false
    @State private var closed = false
    @State private var notice: String?
    @State private var listingError: String?
    @State private var revision = UUID()
    private var current: URL? { path.last }
    private var title: String {
        if !resolvedTitle.isEmpty { return resolvedTitle }
        return DirectoryDisplayName.resolve(component: current?.lastPathComponent ?? "",
                                            localizedName: nil, volumeName: nil, isVolume: false)
    }
    private var validName: Bool {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if current != nil {
                        locationHeader
                        folderList
                    } else if restoring || connecting {
                        ProgressView(L10n.tr("directory.loading.location"))
                            .frame(maxWidth: .infinity).padding(.vertical, 80)
                    } else {
                        emptyLocation
                    }
                }.padding(24)
            }
            .background(LunaColor.paper)
            .navigationTitle(L10n.tr(purpose == .backup ? "directory.backup.title" : "directory.browse.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("directory.cancel")) { closed = true; dismiss() }.disabled(creating)
                }
                ToolbarItem(placement: .primaryAction) {
                    if current != nil {
                        Button(L10n.tr("directory.change.location")) { showingSystem = true }
                            .disabled(connecting || creating)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let current {
                    LunaBottomAction {
                        if creating || connecting {
                            ProgressView(L10n.tr(creating ? "directory.creating" : "directory.loading.location"))
                        }
                        LunaButton(title: L10n.format(purpose == .backup ? "directory.backup.here" : "directory.browse.here", title),
                                   icon: "checkmark", disabled: connecting || creating) { commit(current) }
                    }
                }
            }
            .task { await restore() }
            .task(id: current) { await readTitle() }
            .task(id: "\(current?.absoluteString ?? "")|\(revision)") { await readFolders() }
            .sheet(isPresented: $showingSystem, onDismiss: {
                guard let selected = systemSelection else { return }
                systemSelection = nil
                Task { if await connect(selected) { commit(selected) } }
            }) {
                SystemDirectoryPicker { selected in
                    systemSelection = selected
                    showingSystem = false
                }
            }
            .alert(L10n.tr("directory.create"), isPresented: $showingName) {
                TextField(L10n.tr("directory.name"), text: $folderName)
                Button(L10n.tr("directory.cancel"), role: .cancel) {}
                Button(L10n.tr("directory.create.select")) { Task { await createFolder() } }.disabled(!validName)
            } message: {
                Text(L10n.tr(purpose == .backup ? "directory.create.backup.help" : "directory.create.browse.help"))
            }
            .alert(L10n.tr("directory.error"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button(L10n.tr("copy.96547fdd")) { notice = nil }
            } message: { Text(notice ?? "") }
        }
        .interactiveDismissDisabled(creating)
        .presentationDragIndicator(.visible)
    }

    private var locationHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            if path.count > 1 {
                Button {
                    resolvedTitle = ""; path.removeLast()
                } label: {
                    Label(L10n.tr("directory.parent"), systemImage: "chevron.left")
                        .font(.subheadline).frame(minHeight: 44)
                }.disabled(creating || connecting)
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.fill").lunaFont(28)
                    .foregroundStyle(LunaColor.accent).frame(width: 48, height: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("directory.location.label")).font(.caption).foregroundStyle(LunaColor.muted)
                    Text(title).font(.title3.weight(.semibold)).lineLimit(2)
                    if path.count > 1 {
                        Text(path.dropFirst().map(\.lastPathComponent).joined(separator: " / "))
                            .font(.caption).foregroundStyle(LunaColor.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("directory.folders")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    folderName = ""; showingName = true
                } label: {
                    Label(L10n.tr("directory.create"), systemImage: "folder.badge.plus").font(.subheadline).frame(minHeight: 44).frame(minHeight: 44)
                }.disabled(creating || connecting)
            }
            if loadingFolders {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.tr("directory.loading.folders")).font(.subheadline).foregroundStyle(LunaColor.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            } else if let listingError {
                VStack(alignment: .leading, spacing: 12) {
                    Text(listingError).font(.subheadline).foregroundStyle(LunaColor.muted)
                    Button(L10n.tr("destination.retry")) { revision = UUID() }
                }.padding(.vertical, 16)
            } else if folders.isEmpty {
                Text(L10n.tr("directory.empty"))
                    .font(.subheadline).foregroundStyle(LunaColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(folders, id: \.self) { folder in
                        Button {
                            resolvedTitle = ""; path.append(folder)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").font(.title3).foregroundStyle(LunaColor.accent)
                                Text(folder.lastPathComponent).font(.body).foregroundStyle(LunaColor.ink).lineLimit(2)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(LunaColor.muted)
                            }.frame(minHeight: 56).padding(.horizontal, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(creating || connecting)
                        if folder != folders.last { Divider().padding(.leading, 48) }
                    }
                }.background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var emptyLocation: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageIntro(title: L10n.tr("directory.empty.title"), detail: L10n.tr("directory.empty.body"))
            DriveIllustration()
            LunaButton(title: L10n.tr("directory.connect")) { showingSystem = true }
        }.padding(.vertical, 20)
    }

    private func commit(_ selected: URL) {
        guard !closed else { return }
        closed = true
        onPick(selected)
        dismiss()
    }

    private func restore() async {
        defer { restoring = false }
        if let bookmark = UserDefaults.standard.data(forKey: "folderPickerBookmark") {
            do {
                let access = try await Task.detached(priority: .utility) { try DirectoryAccess(bookmark: bookmark) }.value
                guard !closed, !Task.isCancelled else { return }
                if let initialURL {
                    let root = access.url.standardizedFileURL.path
                    let selected = initialURL.standardizedFileURL.path
                    if selected != root && !selected.hasPrefix(root + "/") {
                        _ = await connect(initialURL); return
                    }
                    var ancestors = [initialURL]
                    var parent = initialURL
                    while parent.standardizedFileURL.path != root {
                        parent.deleteLastPathComponent()
                        ancestors.insert(parent, at: 0)
                    }
                    scope = access; path = ancestors
                } else { scope = access; path = [access.url] }
                return
            } catch { /* Let the user reconnect an unavailable drive. */ }
        }
        if let initialURL { _ = await connect(initialURL) }
    }

    private func connect(_ url: URL) async -> Bool {
        connecting = true
        defer { connecting = false }
        do {
            let (access, bookmark) = try await Task.detached(priority: .userInitiated) {
                let access = try DirectoryAccess(url: url)
                return (access, try access.bookmark())
            }.value
            guard !closed, !Task.isCancelled else { return false }
            scope = access; resolvedTitle = ""; path = [url]; revision = UUID()
            UserDefaults.standard.set(bookmark, forKey: "folderPickerBookmark")
            return true
        } catch { if !closed { notice = error.localizedDescription }; return false }
    }

    private func readTitle() async {
        guard let directory = current, let access = scope else { return }
        let name = await Task.detached(priority: .utility) {
            withExtendedLifetime(access) { DirectoryDisplayName.read(directory) }
        }.value
        guard !closed, !Task.isCancelled, current == directory else { return }
        resolvedTitle = name
    }

    private func readFolders() async {
        guard let directory = current, let access = scope else { return }
        loadingFolders = true; folders = []; listingError = nil
        defer { if !Task.isCancelled, current == directory { loadingFolders = false } }
        let worker = Task.detached(priority: .userInitiated) {
            try withExtendedLifetime(access) {
                let urls = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                return try urls.filter {
                    try Task.checkCancellation()
                    return try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !closed, !Task.isCancelled, current == directory else { return }
            folders = result
        } catch {
            guard !closed, !Task.isCancelled, current == directory else { return }
            listingError = error.localizedDescription
        }
    }

    private func createFolder() async {
        guard validName, let parent = current, let access = scope else { return }
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        creating = true
        defer { creating = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try withExtendedLifetime(access) {
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                }
            }.value
            commit(destination)
        } catch { notice = error.localizedDescription }
    }
}

/// Read provider/volume metadata on a worker, never while laying out a view.
enum DirectoryDisplayName {
    static func read(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey, .volumeNameKey, .isVolumeKey])
        return resolve(component: url.lastPathComponent, localizedName: values?.localizedName,
                       volumeName: values?.volumeName, isVolume: values?.isVolume == true)
    }

    static func resolve(component: String, localizedName: String?, volumeName: String?, isVolume: Bool) -> String {
        let name = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let volume = volumeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isVolume || UUID(uuidString: component) != nil {
            if !name.isEmpty, UUID(uuidString: name) == nil { return name }
            if !volume.isEmpty, UUID(uuidString: volume) == nil { return volume }
            return L10n.tr("directory.external")
        }
        if !name.isEmpty { return name }
        return component.isEmpty ? L10n.tr("directory.external") : component
    }
}

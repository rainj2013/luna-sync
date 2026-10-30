import SwiftUI
import UIKit
import AVKit
import Photos
import ImageIO
import UniformTypeIdentifiers
import LunaSyncPhotoKit

private struct MediaViewerPanel: Identifiable {
    enum Kind { case information, share(URL) }
    let id = UUID()
    let kind: Kind
}

struct MediaViewer: View {
    @State private var urls: [URL]
    @State private var index: Int
    @State private var controlsVisible = true
    @State private var information: MediaFileInformation?
    @State private var panel: MediaViewerPanel?
    @State private var notice: String?
    @State private var working = false
    @State private var confirmingDelete = false
    @State private var needsPhotoPermission = false
    let retainedAccess: DirectoryAccess?
    let deletionAllowed: Bool
    let onDelete: (URL) async throws -> Void
    let onClose: () -> Void
    private let backdrop = Color(white: 0.055)

    init(urls: [URL], initialIndex: Int, retainedAccess: DirectoryAccess?, deletionAllowed: Bool,
         onDelete: @escaping (URL) async throws -> Void, onClose: @escaping () -> Void) {
        _urls = State(initialValue: urls)
        _index = State(initialValue: min(max(0, initialIndex), max(0, urls.count - 1)))
        self.retainedAccess = retainedAccess; self.deletionAllowed = deletionAllowed
        self.onDelete = onDelete; self.onClose = onClose
    }
    private var currentURL: URL? { urls.indices.contains(index) ? urls[index] : nil }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            MediaPageController(urls: urls, index: $index, onTap: { controlsVisible.toggle() }, onClose: {
                if !working { onClose() }
            }).ignoresSafeArea().allowsHitTesting(!working).accessibilityAdjustableAction { direction in
                guard !working else { return }
                if direction == .increment { index = min(index + 1, urls.count - 1) }
                else { index = max(0, index - 1) }
            }
            if controlsVisible {
                VStack(spacing: 0) {
                    header
                    Spacer().allowsHitTesting(false)
                    actions
                }
            }
            if working { ProgressView().tint(.white).padding(20).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16)) }
        }.preferredColorScheme(.dark).foregroundStyle(.white).statusBarHidden(!controlsVisible)
            .interactiveDismissDisabled(working)
            .task(id: currentURL) {
                information = nil
                guard let url = currentURL else { return }
                let result = await MediaImageDecoder.shared.information(for: url)
                guard !Task.isCancelled, currentURL == url else { return }
                information = result
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--review-viewer-info") { panel = MediaViewerPanel(kind: .information) }
                #endif
            }
            #if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("--review-viewer-next"), urls.count > 1 { index = min(index + 1, urls.count - 1) }
            }
            #endif
            .sheet(item: $panel) { panel in
                switch panel.kind {
                case .information: MediaInformationView(url: currentURL, information: information)
                case .share(let url): OriginalFileShareSheet(url: url)
                }
            }
            .alert(L10n.tr("viewer.notice.title"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                if needsPhotoPermission {
                    Button(L10n.tr("settings.system.title")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button(L10n.tr("copy.96547fdd")) { notice = nil }
            } message: { Text(notice ?? "") }
            .confirmationDialog(L10n.tr("files.delete.title"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(L10n.tr("files.delete.action"), role: .destructive) { removeCurrentFile() }
                Button(L10n.tr("directory.cancel"), role: .cancel) {}
            } message: { Text(L10n.format("viewer.delete.message", currentURL?.lastPathComponent ?? "")) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
            }.disabled(working).accessibilityLabel(L10n.tr("viewer.close"))
            VStack(spacing: 4) {
                Text(currentURL?.lastPathComponent ?? "").lunaFont(14, weight: .medium).lineLimit(1).truncationMode(.middle)
                Text(L10n.format("viewer.position", (index + 1).formatted(), urls.count.formatted()))
                    .lunaFont(11).monospacedDigit().foregroundStyle(.white.opacity(0.65))
            }.frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                Button { index = max(0, index - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.disabled(index == 0 || working).accessibilityLabel(L10n.tr("viewer.previous"))
                Button { index = min(urls.count - 1, index + 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }.disabled(index >= urls.count - 1 || working).accessibilityLabel(L10n.tr("viewer.next"))
            }.font(.system(size: 16))
        }.padding(.horizontal, 12).padding(.vertical, 6)
            .background(LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var actions: some View {
        HStack(spacing: 0) {
            action("viewer.info", symbol: "info.circle") { panel = MediaViewerPanel(kind: .information) }
            action("viewer.share", symbol: "square.and.arrow.up") {
                if let url = currentURL { panel = MediaViewerPanel(kind: .share(url)) }
            }
            action("viewer.save", symbol: "square.and.arrow.down") { saveCurrentFile() }
            action("files.delete.action", symbol: "trash", enabled: deletionAllowed) { confirmingDelete = true }
        }.padding(.horizontal, 20).padding(.vertical, 2)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
    }
    private func action(_ title: String, symbol: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr(title))
            .disabled(!enabled || working || currentURL == nil).opacity(enabled ? 1 : 0.35)
    }

    private func saveCurrentFile() {
        guard let url = currentURL, !working else { return }
        working = true; needsPhotoPermission = false
        let scope = retainedAccess
        Task {
            defer { working = false; withExtendedLifetime(scope) {} }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                needsPhotoPermission = true; notice = L10n.tr("viewer.save.permission"); return
            }
            do {
                let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false; options.originalFilename = url.lastPathComponent
                    request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
                }
                notice = L10n.tr("viewer.save.success")
            } catch { notice = L10n.format("viewer.save.failure", error.localizedDescription) }
        }
    }
    private func removeCurrentFile() {
        guard let url = currentURL, deletionAllowed, !working else { return }
        working = true; needsPhotoPermission = false
        Task {
            defer { working = false }
            do {
                try await onDelete(url)
                urls.removeAll { $0 == url }
                if urls.isEmpty { onClose() }
                else { index = min(index, urls.count - 1) }
            } catch { notice = error.localizedDescription }
        }
    }
}

private struct MediaFileInformation: Sendable {
    var byteCount: Int64?
    var dimensions: String?
    var capturedAt: Date?
    var modifiedAt: Date?
    var camera: String?
    var duration: String?
}

/// Serial, cancellable-before-decoding requests limit memory during fast paging.
/// Decoded images belong only to the current/adjacent page controllers; no cache
/// files or full-original Data buffers are created by the viewer.
private actor MediaImageDecoder {
    static let shared = MediaImageDecoder()
    func image(at url: URL, maxPixels: Int) throws -> UIImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return UIImage(cgImage: image)
    }
    func information(for url: URL) async -> MediaFileInformation {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var result = MediaFileInformation(byteCount: values?.fileSize.map(Int64.init), modifiedAt: values?.contentModificationDate)
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            let asset = AVURLAsset(url: url)
            if let time = try? await asset.load(.duration), time.seconds.isFinite {
                let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.hour, .minute, .second]
                formatter.zeroFormattingBehavior = .pad; formatter.unitsStyle = .positional
                result.duration = formatter.string(from: max(0, time.seconds))
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let display = size.applying(transform)
                result.dimensions = "\(Int(abs(display.width))) × \(Int(abs(display.height)))"
            }
            return result
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return result }
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            result.dimensions = (5...8).contains(orientation) ? "\(height) × \(width)" : "\(width) × \(height)"
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            result.capturedAt = formatter.date(from: date)
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.camera = tiff[kCGImagePropertyTIFFModel] as? String
        }
        return result
    }
}

private struct MediaInformationView: View {
    let url: URL?
    let information: MediaFileInformation?
    var body: some View {
        NavigationStack {
            Form {
                if let url {
                    row("viewer.info.filename", url.lastPathComponent)
                    row("viewer.info.format", url.pathExtension.uppercased())
                    if let bytes = information?.byteCount { row("viewer.info.size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    if let size = information?.dimensions { row("viewer.info.dimensions", size) }
                    if let date = information?.capturedAt { row("viewer.info.captured", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = information?.modifiedAt { row("viewer.info.modified", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let camera = information?.camera { row("viewer.info.camera", camera) }
                    if let duration = information?.duration { row("viewer.info.duration", duration) }
                    row("viewer.info.folder", url.deletingLastPathComponent().lastPathComponent)
                    if information == nil { ProgressView(L10n.tr("viewer.info.loading")) }
                }
            }.navigationTitle(L10n.tr("viewer.info")).navigationBarTitleDisplayMode(.inline)
        }.preferredColorScheme(.light).tint(LunaColor.accent).presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(L10n.tr(title)) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }
}

private struct OriginalFileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// UIKit's page data source creates only immediate neighbors, even for huge folders.
private struct MediaPageController: UIViewControllerRepresentable {
    let urls: [URL]
    @Binding var index: Int
    let onTap: () -> Void
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        context.coordinator.controller = controller
        controller.dataSource = context.coordinator; controller.delegate = context.coordinator
        if urls.indices.contains(index) { controller.setViewControllers([context.coordinator.page(index)], direction: .forward, animated: false) }
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard urls.indices.contains(index) else { return }
        let current = controller.viewControllers?.first as? MediaPage
        if current?.url != urls[index] {
            controller.dataSource = context.coordinator
            controller.setViewControllers([context.coordinator.page(index)], direction: index < (current?.position ?? 0) ? .reverse : .forward, animated: false)
        }
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MediaPageController
        weak var controller: UIPageViewController?
        init(_ parent: MediaPageController) { self.parent = parent }
        private func index(of page: MediaPage) -> Int? {
            if parent.urls.indices.contains(page.position), parent.urls[page.position] == page.url { return page.position }
            return parent.urls.firstIndex(of: page.url)
        }
        func page(_ index: Int) -> UIViewController {
            let url = parent.urls[index]
            return MediaPage(url: url, position: index, onTap: parent.onTap, onClose: parent.onClose, onZoom: { [weak self] zoomed in
                guard let self, (self.controller?.viewControllers?.first as? MediaPage)?.url == url else { return }
                if zoomed, self.controller?.dataSource != nil { self.controller?.dataSource = nil }
                else if !zoomed, self.controller?.dataSource == nil { self.controller?.dataSource = self }
            })
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? MediaPage, let index = index(of: current), index > 0 else { return nil }
            return page(index - 1)
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? MediaPage, let index = index(of: current), index + 1 < parent.urls.count else { return nil }
            return page(index + 1)
        }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let page = controller.viewControllers?.first as? MediaPage, let index = index(of: page) { parent.index = index }
        }
    }
}

private final class MediaPage: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let url: URL
    let position: Int
    let onTap: () -> Void
    let onClose: () -> Void
    let onZoom: (Bool) -> Void
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failure = UILabel()
    private var player: AVPlayerViewController?
    private var loading: Task<Void, Never>?
    private var qualityLoading: Task<Void, Never>?
    private var requestedDetail = false
    private var laidOutSize = CGSize.zero
    private var visible = false

    init(url: URL, position: Int, onTap: @escaping () -> Void, onClose: @escaping () -> Void, onZoom: @escaping (Bool) -> Void) {
        self.url = url; self.position = position; self.onTap = onTap; self.onClose = onClose; self.onZoom = onZoom
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.055, alpha: 1)
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            let controller = AVPlayerViewController(); controller.player = AVPlayer(url: url)
            controller.allowsPictureInPicturePlayback = false
            addChild(controller); view.addSubview(controller.view); controller.didMove(toParent: self); player = controller
            return
        }
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.isEnabled = false
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(imageView); view.addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        view.addSubview(spinner); spinner.color = .white
        failure.text = L10n.tr("viewer.load.failure"); failure.textColor = .lightGray
        failure.font = .preferredFont(forTextStyle: .body); failure.numberOfLines = 0; failure.textAlignment = .center
        failure.adjustsFontForContentSizeCategory = true
        failure.isHidden = true; view.addSubview(failure)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:))); doubleTap.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped)); single.require(toFail: doubleTap)
        scroll.addGestureRecognizer(single); scroll.addGestureRecognizer(doubleTap)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(close)); down.direction = .down; down.delegate = self
        scroll.addGestureRecognizer(down)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); visible = true
        if player != nil { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) }
        guard player == nil, imageView.image == nil else { return }
        spinner.startAnimating(); failure.isHidden = true
        requestedDetail = false
        let pixels = max(1024, Int(min(4096, max(view.bounds.width, view.bounds.height) * (view.window?.screen.scale ?? 3) * 1.5)))
        loading = Task { [weak self, url] in
            do {
                let image = try await MediaImageDecoder.shared.image(at: url, maxPixels: pixels)
                guard !Task.isCancelled, let self, self.visible else { return }
                self.imageView.image = image; self.fitImage(); self.spinner.stopAnimating()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--review-viewer-zoom") {
                    self.zoomIn(at: CGPoint(x: self.imageView.bounds.midX, y: self.imageView.bounds.midY))
                }
                #endif
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.spinner.stopAnimating(); self.failure.isHidden = false
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); visible = false
        loading?.cancel(); loading = nil; imageView.image = nil; player?.player?.pause()
        qualityLoading?.cancel(); qualityLoading = nil
        if player != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); scroll.frame = view.bounds; player?.view.frame = view.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        failure.frame = view.bounds.insetBy(dx: 30, dy: view.bounds.height * 0.35)
        if laidOutSize != view.bounds.size { laidOutSize = view.bounds.size; fitImage() }
    }
    private func fitImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        scroll.setZoomScale(1, animated: false)
        let scale = min(scroll.bounds.width / image.size.width, scroll.bounds.height / image.size.height)
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
        scroll.contentSize = imageView.frame.size; centerImage()
        scroll.setContentOffset(CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top), animated: false)
    }
    private func centerImage() {
        let vertical = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
        let horizontal = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        scroll.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        let zoomed = scrollView.zoomScale > 1.01
        scrollView.panGestureRecognizer.isEnabled = zoomed
        onZoom(zoomed)
        if scrollView.zoomScale > 1.6, !requestedDetail, visible {
            requestedDetail = true
            qualityLoading = Task { [weak self, url] in
                guard let image = try? await MediaImageDecoder.shared.image(at: url, maxPixels: 6144),
                      !Task.isCancelled, let self, self.visible else { return }
                self.imageView.image = image
            }
        }
    }
    @objc private func zoom(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
        else { zoomIn(at: gesture.location(in: imageView)) }
    }
    private func zoomIn(at point: CGPoint, animated: Bool = true) {
        let scale: CGFloat = 2.5
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }
    @objc private func tapped() { onTap() }
    @objc private func close() { onClose() }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { scroll.zoomScale <= 1.01 }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UISwipeGestureRecognizer && scroll.zoomScale <= 1.01
    }
    #if DEBUG && targetEnvironment(simulator)
    func checkReviewGestures() async throws {
        loadViewIfNeeded(); view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        view.setNeedsLayout(); view.layoutIfNeeded(); viewWillAppear(false)
        await loading?.value
        guard imageView.image != nil else { throw NSError(domain: "ViewerReview.load", code: 1) }
        let frame = view.convert(imageView.bounds, from: imageView)
        guard abs(frame.midX - view.bounds.midX) < 1, abs(frame.midY - view.bounds.midY) < 1 else {
            throw NSError(domain: "ViewerReview.centering", code: 2)
        }
        zoomIn(at: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), animated: false)
        guard scroll.zoomScale > 1.5, scroll.panGestureRecognizer.isEnabled else { throw NSError(domain: "ViewerReview.zoomIn", code: 3) }
        scroll.setZoomScale(1, animated: false)
        guard !scroll.panGestureRecognizer.isEnabled else { throw NSError(domain: "ViewerReview.restorePaging", code: 4) }
        viewDidDisappear(false)
        guard imageView.image == nil else { throw NSError(domain: "ViewerReview.release", code: 5) }
    }
    #endif
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum MediaViewerReviewChecks {
    static func run() async {
        var report: [String: Any] = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ViewerDecoderReview")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("rotated.jpg")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800), format: format).image { context in
                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
            }
            guard let cg = image.cgImage,
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw NSError(domain: "ViewerReview.fixture", code: 1)
            }
            CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ViewerReview.fixture", code: 2) }
            let before = try Data(contentsOf: url)
            let preview = try await MediaImageDecoder.shared.image(at: url, maxPixels: 256)
            let information = await MediaImageDecoder.shared.information(for: url)
            guard preview.size.width <= 256, preview.size.height <= 256,
                  preview.size.height > preview.size.width, information.dimensions == "800 × 1600" else {
                throw NSError(domain: "ViewerReview.orientationAndBound", code: 3)
            }
            var missingRejected = false
            do { _ = try await MediaImageDecoder.shared.image(at: root.appendingPathComponent("missing.jpg"), maxPixels: 256) }
            catch { missingRejected = true }
            guard missingRejected else { throw NSError(domain: "ViewerReview.missing", code: 4) }
            let controller = MediaPage(url: url, position: 0, onTap: {}, onClose: {}, onZoom: { _ in })
            try await controller.checkReviewGestures()
            guard try Data(contentsOf: url) == before else { throw NSError(domain: "ViewerReview.originalChanged", code: 5) }
            report = ["passed": true, "checks": ["bounded decoding", "EXIF orientation", "metadata dimensions", "missing-file handling", "image centering", "zoom and pan", "paging restored after zoom", "image released on leave", "original bytes unchanged"]]
        } catch { report = ["passed": false, "error": String(describing: error)] }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DesignReview")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("media-viewer-checks.json"), options: .atomic)
    }
}
#endif

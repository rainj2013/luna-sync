import SwiftUI
import Photos
import LunaSyncCore
import LunaSyncPhotoKit

struct ContentView: View {
    @ObservedObject var model: BackupModel
    @StateObject private var browser = DiskBrowserModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var showingBrowserDirectory = false
    @State private var tab = 0
    @State private var showingPreparation = false
    @State private var showingSettings = false
    @State private var showingProgress = false
    @State private var startAfterPreparation = false
    @State private var showingScan = false
    @State private var startAfterScan = false
    @State private var showingIntegrityReview = false
    @State private var showingRangeReview = false
    #if DEBUG
    @State private var showingScopeReview = false
    @State private var showingDirectoryReview = false
    @State private var reviewDirectoryURL: URL?
    #endif
    private var reviewWelcome: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--review-screen"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] == "welcome"
        }
        #endif
        return false
    }

    var body: some View {
        Group {
            if model.restoring {
                ZStack { LunaBackdrop(); ProgressView() }
            } else if reviewWelcome || (!onboardingComplete && model.archive == nil && !model.hasSavedDestination) {
                WelcomeView {
                    onboardingComplete = true
                    showingPreparation = true
                }
            } else {
                Group {
                    switch tab {
                    case 1: NavigationStack { HistoryView(model: model, close: { tab = 0 }) }
                    case 2: DiskBrowserView(model: browser, showingPicker: $showingBrowserDirectory, deletionAllowed: !model.busy && !model.scanning && !model.connecting)
                    default:
                        NavigationStack {
                            OverviewView(model: model, showSettings: { showingSettings = true })
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if tab == 0 {
                            LunaBottomAction {
                                HomeBackupAction(model: model, prepare: prepare, showProgress: { showingProgress = true })
                            }
                        }
                        if tab == 2 && (browser.rootURL == nil || browser.needsReconnect) {
                            LunaBottomAction {
                                LunaButton(title: L10n.tr("copy.a664b64a"), disabled: browser.deleting) { showingBrowserDirectory = true }
                            }
                        }
                        LunaTabBar(selection: $tab).disabled(browser.deleting)
                    }.background(LunaColor.paper)
                }
            }
        }
        .font(.body).foregroundStyle(LunaColor.ink).tint(LunaColor.accent)
        .preferredColorScheme(.light)
        .background(LunaColor.paper.ignoresSafeArea())
        .fullScreenCover(isPresented: $showingPreparation, onDismiss: {
            if startAfterPreparation {
                startAfterPreparation = false
                model.start()
                if model.runState == .running { showingProgress = true }
            }
        }) {
            SetupView(model: model) {
                startAfterPreparation = true
                showingPreparation = false
            }
            .foregroundStyle(LunaColor.ink).tint(LunaColor.accent).preferredColorScheme(.light)
        }
        .fullScreenCover(isPresented: $showingSettings) {
            NavigationStack { SettingsView(model: model) }.foregroundStyle(LunaColor.ink).tint(LunaColor.accent).preferredColorScheme(.light)
        }
        .fullScreenCover(isPresented: $showingScan, onDismiss: {
            if startAfterScan {
                startAfterScan = false
                model.start()
                if model.runState == .running { showingProgress = true }
            }
        }) {
            NavigationStack {
                ScanPreviewView(model: model) { startAfterScan = true; showingScan = false }
            }.foregroundStyle(LunaColor.ink).tint(LunaColor.accent).preferredColorScheme(.light)
        }
        .fullScreenCover(isPresented: $showingIntegrityReview) {
            NavigationStack { IntegrityView(model: model) }.foregroundStyle(LunaColor.ink).tint(LunaColor.accent).preferredColorScheme(.light)
        }
        .fullScreenCover(isPresented: $showingRangeReview) {
            ZLPhotoLibraryPicker(isPresented: $showingRangeReview, initialSelection: [], includeVideos: true, selectionStyle: .range) { _ in }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingProgress) {
            NavigationStack {
                TransferView(model: model, showFiles: {
                    showingProgress = false; tab = 2
                })
            }
            .foregroundStyle(LunaColor.ink).tint(LunaColor.accent).preferredColorScheme(.light)
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showingScopeReview) { PhotoScopeSheet(model: model) }
        .sheet(isPresented: $showingDirectoryReview) {
            DirectoryPicker(initialURL: reviewDirectoryURL) { _ in }
        }
        #endif
        .alert(L10n.tr("app.name"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(L10n.tr("copy.96547fdd")) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshDestinationAvailability()
                await browser.refreshAvailability()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        #if DEBUG
        .task(id: model.restoring) {
            guard !model.restoring,
                  let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--review-screen"),
                  ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return }
            let screen = ProcessInfo.processInfo.arguments[index + 1]
            onboardingComplete = screen != "welcome"
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--design-fixture") {
                do {
                    let root = try await model.prepareDesignReview(screen)
                    if screen == "files-grid" || screen.hasPrefix("viewer") { browser.select(root) }
                } catch { model.notice = error.localizedDescription }
            }
            #endif
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--review-media-checks") { await MediaViewerReviewChecks.run() }
            #endif
            switch screen {
            case "settings": showingSettings = true
            case "setup", "setup1", "setup2": showingPreparation = true
            case "history": tab = 1
            case "files", "files-grid", "viewer", "viewer-info", "viewer-next", "viewer-zoom", "viewer-video": tab = 2
            case "errors": model.runState = .failed; showingProgress = true
            case "scanning": model.scanning = true; showingScan = true
            case "paused": model.runState = .paused; showingProgress = true
            case "complete": model.runState = .completed; showingProgress = true
            case "active": model.runState = .running; model.busy = true; showingProgress = true
            case "scan": showingScan = true
            case "integrity": showingIntegrityReview = true
            case "performance":
                Task {
                    do {
                        let source = PhotoKitSource()
                        let start = Date()
                        let first = try await source.scan(includeVideos: true)
                        let firstSeconds = Date().timeIntervalSince(start)
                        let firstStatistics = source.scanCacheStatistics
                        let next = Date()
                        let second = try await source.scan(includeVideos: true)
                        let secondSeconds = Date().timeIntervalSince(next)
                        let secondStatistics = source.scanCacheStatistics
                        let unchanged = await Task.detached { first == second }.value
                        let report: [String: Any] = [
                            "generatedAt": Date().ISO8601Format(), "assets": first.count,
                            "startupUIReadySeconds": model.startupUIReadySeconds,
                            "firstScanSeconds": firstSeconds, "repeatScanSeconds": secondSeconds,
                            "firstScanResourceQueries": firstStatistics["resourceQueries"] ?? 0,
                            "repeatScanResourceQueries": (secondStatistics["resourceQueries"] ?? 0) - (firstStatistics["resourceQueries"] ?? 0),
                            "repeatScanCacheHits": (secondStatistics["hits"] ?? 0) - (firstStatistics["hits"] ?? 0),
                            "descriptorsUnchanged": unchanged,
                            "issues": second.filter { $0.issue != nil }.count
                        ]
                        try await Task.detached {
                            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DesignReview")
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                                .write(to: folder.appendingPathComponent("scan-performance.json"), options: .atomic)
                        }.value
                    } catch { model.notice = error.localizedDescription }
                }
            case "background": BackgroundBackupProbe.shared.start()
            case "resources":
                Task { _ = try? await PhotoKitSource().scan(includeVideos: true) }
            case "range": showingRangeReview = true
            case "scope", "scope-dates", "scope-manual": showingScopeReview = true
            case "directory":
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("旅行照片", isDirectory: true)
                for name in ["2025 年", "2026 年", "家庭相册"] {
                    try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
                }
                reviewDirectoryURL = root
                showingDirectoryReview = true
            default: break
            }
            if screen == "range" { try? await Task.sleep(for: .seconds(2)) }
            if screen == "files" || screen == "files-grid" || screen.hasPrefix("viewer") { try? await Task.sleep(for: .seconds(8)) }
            await AppReviewCapture.capture(screen)
        }
        #endif
    }

    private func prepare() {
        if model.canStart && (model.authorization == .authorized || model.authorization == .limited) {
            showingScan = true
        } else { showingPreparation = true }
    }
}


struct WelcomeView: View {
    let begin: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    MemoryAlbumIllustration(size: 26)
                    Text(L10n.tr("app.name")).lunaFont(20, weight: .semibold)
                }.padding(.top, 20)
                MemoryAlbumIllustration(size: 195)
                    .frame(maxWidth: .infinity).padding(.top, 42).padding(.bottom, 40)
                Text(L10n.tr("design.welcome.title"))
                    .lunaFont(32, weight: .semibold).tracking(-0.5).lineSpacing(5)
                Text(L10n.tr("design.welcome.body")).lunaFont(15).lineSpacing(7)
                    .foregroundStyle(LunaColor.muted).padding(.top, 18)
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }.background(LunaColor.paper)
            .safeAreaInset(edge: .bottom) {
                LunaBottomAction {
                    LunaButton(title: L10n.tr("copy.499be303"), icon: "arrow.right", action: begin)
                    Text(L10n.tr("copy.2adedcd5")).lunaFont(12).foregroundStyle(LunaColor.muted)
                        .padding(.vertical, 4)
                }
            }
    }
}


struct OverviewView: View {
    @ObservedObject var model: BackupModel
    let showSettings: () -> Void
    @State private var showingScope = false
    @State private var showingDirectory = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var active: Bool { model.runState == .running || model.isVerifying }
    private var connected: Bool { model.archive != nil && !model.destinationNeedsReconnect }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    MemoryAlbumIllustration(size: 28)
                    Text(L10n.tr("app.name")).lunaFont(22, weight: .semibold, relativeTo: .title2)
                    Spacer(minLength: 8)
                    Button(action: showSettings) {
                        Image(systemName: "gearshape").font(.system(size: 17))
                            .frame(width: 38, height: 38).background(.white, in: Circle())
                            .overlay { Circle().stroke(LunaColor.border) }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel(L10n.tr("copy.f3c259dd"))
                }.frame(minHeight: 44).padding(.bottom, 24)
                backupCard
                LunaSectionLabel(title: L10n.tr("family.destination.label"))
                Button { showingDirectory = true } label: { DestinationCard(model: model) }.buttonStyle(.plain)
                    .disabled(model.busy || model.scanning || model.connecting)
                if model.destinationNeedsReconnect {
                    HStack(alignment: .top, spacing: 8) {
                        Text(L10n.tr("ui.home.reconnect")).lunaFont(12).lineSpacing(4).foregroundStyle(LunaColor.muted)
                        Spacer(minLength: 0)
                        Button(L10n.tr("destination.retry")) { Task { await model.reconnectDirectory() } }
                            .lunaFont(12, weight: .medium).frame(minWidth: 44, minHeight: 44).disabled(model.connecting)
                    }.padding(.top, 10)
                }
                if connected {
                    LunaStatPair(firstTitle: L10n.tr("ui.home.saved"), firstValue: model.storedCount.formatted(),
                                 secondTitle: L10n.tr("ui.complete.saved"), secondValue: model.preview?.pendingCount.formatted() ?? "—")
                        .padding(.top, 12)
                }
                LunaSectionLabel(title: L10n.tr("copy.03f75d4c"))
                Button { showingScope = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(LunaColor.accent)
                            .frame(width: 44, height: 44).background(LunaColor.panel, in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.selectionSummary).lunaFont(14, weight: .semibold).foregroundStyle(LunaColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.tr(model.includeVideos ? "home.media.all" : "home.media.photos"))
                                .lunaFont(11).foregroundStyle(LunaColor.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").lunaFont(13).foregroundStyle(LunaColor.muted)
                    }.padding(14).frame(minHeight: LunaLayout.rowHeight).lunaSurface()
                }.buttonStyle(.plain).disabled(model.busy || model.scanning || model.connecting)
                if model.limitedAccess {
                    Text(L10n.tr("copy.05685922")).lunaFont(11).foregroundStyle(LunaColor.warning).padding(.top, 14)
                }
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingDirectory) {
                DirectoryPicker(initialURL: model.archiveURL) { model.selectDirectory($0) }
            }
            .fullScreenCover(isPresented: $showingScope, onDismiss: {
                guard model.authorization == .authorized || model.authorization == .limited else { return }
                Task { await model.scanPreview(showErrors: false) }
            }) { PhotoScopeSheet(model: model) }
            .task(id: model.canStart) {
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--review-screen"), arguments.indices.contains(index + 1), arguments[index + 1] != "overview" { return }
                #endif
                if model.canStart, model.preview == nil, model.authorization == .authorized || model.authorization == .limited {
                    await model.scanPreview(showErrors: false)
                }
            }
    }

    private var backupCard: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("home.status.label")).lunaFont(12).foregroundStyle(LunaColor.muted)
                Text(heroTitle).lunaFont(24, weight: .semibold, relativeTo: .title2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(heroDetail).lunaFont(12).foregroundStyle(LunaColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { MemoryAlbumIllustration(size: 88) }
        }.padding(20).frame(minHeight: 178)
            .background(LunaColor.panel, in: RoundedRectangle(cornerRadius: LunaLayout.heroRadius))
    }

    private var heroTitle: String {
        if model.connecting { return L10n.tr("destination.checking") }
        if !connected { return L10n.tr("copy.ff8708ea") }
        if active { return model.status }
        if model.runState == .paused { return L10n.tr("copy.4e8fd14b") }
        if model.scanning { return L10n.tr("ui.home.checking") }
        if let preview = model.preview, preview.pendingCount == 0, preview.issues.isEmpty { return L10n.tr("ui.home.current") }
        return L10n.tr("home.status.ready")
    }
    private var heroDetail: String {
        if !connected { return L10n.tr("ui.home.connect") }
        if active { return L10n.format("copy.91c3704b", model.completed.formatted(), model.total.formatted()) }
        if let preview = model.preview {
            return preview.pendingCount == 0 && preview.issues.isEmpty ? L10n.tr("ui.home.noNew") :
                L10n.format("ui.home.new", preview.pendingCount.formatted())
        }
        return L10n.tr("ui.home.incremental")
    }
}


/// Share the root bottom inset with navigation so the primary action cannot sit behind the tabs.
private struct HomeBackupAction: View {
    @ObservedObject var model: BackupModel
    let prepare: () -> Void
    let showProgress: () -> Void
    private var active: Bool { model.runState == .running || model.isVerifying }
    var body: some View {
        LunaButton(title: L10n.tr(active ? "copy.0176a528" : model.runState == .paused ? "copy.6abd292d" : "design.overview.start"),
                   disabled: model.isVerifying || (!active && (
                       model.busy || model.connecting || model.scanning || model.archive == nil ||
                       model.destinationNeedsReconnect || model.requiresDestinationConfirmation ||
                       model.selectedPhotoIDs?.isEmpty == true))) {
            if active || model.runState == .paused || model.runState == .failed { showProgress() }
            else { prepare() }
        }
    }
}


struct DestinationCard: View {
    @ObservedObject var model: BackupModel
    var showsStatus = true
    @Environment(\.dynamicTypeSize) private var typeSize
    private var unavailable: Bool { model.archive == nil || model.destinationNeedsReconnect }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive").font(.system(size: 20)).foregroundStyle(LunaColor.accent)
                .frame(width: 44, height: 44).background(LunaColor.panel, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.connecting && model.archive == nil ? L10n.tr("destination.checking") : unavailable ? L10n.tr("copy.ff8708ea") : model.destinationSummary)
                    .lunaFont(14, weight: .semibold).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
                Text(model.destinationNeedsReconnect ? L10n.tr("ui.destination.unavailable") :
                    model.availableBytes.map { L10n.format("copy.edfd0761", ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) } ?? L10n.tr("copy.3777c0b4"))
                    .lunaFont(11).foregroundStyle(LunaColor.muted).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsStatus && !typeSize.isAccessibilitySize {
                StatusPill(title: model.connecting ? L10n.tr("destination.checking") : model.requiresDestinationConfirmation ? L10n.tr("storage.confirm.title") : unavailable ? L10n.tr("destination.disconnected") : L10n.tr("destination.connected"),
                           warning: unavailable || model.requiresDestinationConfirmation,
                           neutral: model.connecting)
            } else { Image(systemName: "chevron.right").lunaFont(13).foregroundStyle(LunaColor.muted) }
        }.padding(14).frame(minHeight: LunaLayout.rowHeight).lunaSurface()
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    let start: () -> Void
    @State private var stage = 0
    @State private var showingDirectory = false
    @State private var showingScope = false
    @State private var showingSource = false
    @State private var showingPreview = false
    @State private var continueAfterSource = false
    @State private var advancingAfterPick = false
    private var unavailable: Bool { model.archive == nil || model.destinationNeedsReconnect || model.requiresDestinationConfirmation }
    private var working: Bool { model.busy || model.connecting || model.scanning }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { if stage == 0 { dismiss() } else { stage = 0 } } label: {
                            Image(systemName: "chevron.left").lunaFont(18).frame(width: 44, height: 44, alignment: .leading)
                        }
                        Spacer()
                        Text(stage == 0 ? "1 / 2" : "2 / 2").lunaFont(12).foregroundStyle(LunaColor.muted)
                    }.frame(minHeight: 44).padding(.bottom, 24)
                    if stage == 0 { driveStep } else { photoStep }
                }.lunaPage()
            }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom) {
                    LunaBottomAction {
                        if model.connecting { ProgressView().controlSize(.small) }
                        LunaButton(title: stage == 0 ? L10n.tr("copy.ff8708ea") : L10n.tr("design.setup.scan"),
                            icon: stage == 0 ? "arrow.right" : nil, disabled: working || (stage == 1 && model.selectedPhotoIDs?.isEmpty == true)) {
                            if stage == 0 {
                                advancingAfterPick = true
                                showingDirectory = true
                            } else if unavailable {
                                stage = 0
                            } else if model.selectedSource == nil {
                                continueAfterSource = true; showingSource = true
                            } else { showingPreview = true }
                        }
                    }
                }
                .navigationDestination(isPresented: $showingPreview) { ScanPreviewView(model: model, start: start) }
        }
        .interactiveDismissDisabled(model.scanning)
        .sheet(isPresented: $showingDirectory) { DirectoryPicker(initialURL: model.archiveURL) { model.selectDirectory($0) } }
        .fullScreenCover(isPresented: $showingScope) { PhotoScopeSheet(model: model) }
        .sheet(isPresented: $showingSource, onDismiss: {
            if continueAfterSource && model.selectedSource != nil { showingPreview = true }
            continueAfterSource = false
        }) { SourceChoiceView(model: model) }
        .onChange(of: model.connecting) { _, connecting in
            if !connecting && advancingAfterPick && !unavailable {
                advancingAfterPick = false; stage = 1
            }
        }
        .onAppear {
            stage = unavailable ? 0 : 1
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("setup1") { stage = 0 }
            if ProcessInfo.processInfo.arguments.contains("setup2") { stage = 1 }
            #endif
        }
    }

    private var driveStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            LunaEyebrow(title: L10n.tr("design.setup.drive.eyebrow")).padding(.bottom, 10)
            PageIntro(title: L10n.tr("design.setup.drive.title"), detail: L10n.tr("design.setup.drive.body"))
            DriveIllustration().padding(.top, 36).padding(.bottom, 31)
            if model.requiresDestinationConfirmation {
                Text(L10n.tr("storage.confirm.body")).lunaFont(12).foregroundStyle(LunaColor.muted).lineSpacing(6).padding(.bottom, 16)
            }
            Text(L10n.tr("copy.575953fe")).lunaFont(13, weight: .semibold).padding(.bottom, 12)
            Button { showingDirectory = true; advancingAfterPick = true } label: { DestinationCard(model: model) }.buttonStyle(.plain).disabled(working)
            Text(L10n.tr("design.setup.drive.footer")).lunaFont(12).lineSpacing(5)
                .foregroundStyle(LunaColor.muted).padding(.horizontal, 5).padding(.top, 14)
            if model.destinationNeedsReconnect {
                Button(L10n.tr("destination.retry")) { Task { await model.reconnectDirectory(); if !unavailable { stage = 1 } } }
                    .lunaFont(12).padding(.top, 12).disabled(working)
            }
        }
    }

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            LunaEyebrow(title: L10n.tr("design.setup.photo.eyebrow")).padding(.bottom, 10)
            PageIntro(title: L10n.tr("design.setup.photo.title"), detail: L10n.tr("design.setup.photo.body"))
            Button {
                Task {
                    await model.requestPhotos()
                    if model.authorization == .denied, let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "photo").lunaFont(19).foregroundStyle(LunaColor.accent)
                        .frame(width: 42, height: 42).background(LunaColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("backup.photos.allow")).lunaFont(12, weight: .semibold)
                        Text(L10n.tr("design.setup.originals")).lunaFont(10).foregroundStyle(LunaColor.muted)
                    }
                    Spacer(minLength: 3)
                    StatusPill(title: model.authorization == .authorized ? L10n.tr("copy.484cc7ec") : model.limitedAccess ? L10n.tr("copy.41067fd6") : L10n.tr("copy.06562b4f"), warning: model.authorization != .authorized)
                }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(LunaColor.border) }
            }.buttonStyle(.plain).padding(.top, 30).padding(.bottom, 14)
            Button { showingDirectory = true } label: { DestinationCard(model: model, showsStatus: false) }.buttonStyle(.plain)
            Button { showingScope = true } label: {
                HStack(spacing: 13) {
                    Image(systemName: "rectangle.stack").lunaFont(18).foregroundStyle(LunaColor.accent).frame(width: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("copy.03f75d4c")).lunaFont(12, weight: .semibold)
                        Text(model.selectionSummary).lunaFont(10).foregroundStyle(LunaColor.muted)
                    }
                    Spacer(); Image(systemName: "chevron.right").lunaFont(12).foregroundStyle(LunaColor.muted)
                }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(LunaColor.border) }
            }.buttonStyle(.plain).padding(.top, 14)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield").foregroundStyle(LunaColor.accent).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("design.setup.privacy.title")).lunaFont(12, weight: .semibold)
                    Text(L10n.tr("design.setup.privacy.body")).lunaFont(12).lineSpacing(7).foregroundStyle(LunaColor.muted)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(LunaColor.panel, in: RoundedRectangle(cornerRadius: 18)).padding(.top, 21)
            Text(L10n.tr("copy.fe60350b")).lunaFont(13, weight: .semibold).padding(.top, 25).padding(.bottom, 12)
            Text(L10n.tr("storage.flat.example")).lunaFont(11, design: .monospaced).lineSpacing(8)
                .foregroundStyle(LunaColor.muted).padding(.horizontal, 8)
        }.disabled(working)
    }
}

struct ScanPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    let start: () -> Void
    @State private var showingScope = false
    private var readyTitle: String {
        guard let preview = model.preview else { return L10n.tr("ui.scan.confirm") }
        if preview.pendingCount == 0 {
            return L10n.tr(preview.issues.isEmpty ? "ui.home.current" : "ui.scan.attention")
        }
        return L10n.format("ui.scan.new", preview.pendingCount.formatted())
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LunaHeader(title: L10n.tr(model.scanning ? "ui.scan.title" : "ui.scan.confirm"), back: { dismiss() })
                    .disabled(model.scanning).padding(.bottom, 28)
                PageIntro(title: model.scanning ? L10n.tr("ui.scan.checking") : readyTitle, detail: L10n.tr("copy.bd3c0200"))
                if model.scanning {
                    VStack(spacing: 20) {
                        ProgressView().controlSize(.large).tint(LunaColor.accent)
                        Text(L10n.tr("ui.scan.metadata")).lunaFont(13).foregroundStyle(LunaColor.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                        .background(LunaColor.panel, in: RoundedRectangle(cornerRadius: LunaLayout.heroRadius)).padding(.top, 28)
                } else if let preview = model.preview {
                    LunaStatPair(firstTitle: L10n.tr("copy.6ce78c7d"), firstValue: preview.pendingCount.formatted(),
                                 secondTitle: L10n.tr("copy.1d3d2487"), secondValue: preview.completed.formatted(), accentSecond: false)
                        .padding(.top, 24)
                    VStack(spacing: 12) {
                        countRow(L10n.tr("copy.de93c953"), preview.photoCount)
                        countRow(L10n.tr("copy.5e6f06f8"), preview.videoCount)
                        if !preview.issues.isEmpty {
                            countRow(L10n.tr("scan.review.count"), preview.issues.count).foregroundStyle(LunaColor.warning)
                        }
                    }.padding(18).lunaSurface().padding(.top, 12)
                    Button { showingScope = true } label: {
                        HStack {
                            Text(L10n.tr("copy.03f75d4c")).foregroundStyle(LunaColor.muted)
                            Spacer(minLength: 8)
                            Text(model.selectionSummary).multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.down").lunaFont(11)
                        }.lunaFont(13).frame(minHeight: 44)
                    }.accessibilityLabel(L10n.tr("copy.15b87fe2")).padding(.top, 8)
                    if preview.pendingCount > 0 {
                        LunaSectionLabel(title: L10n.tr("scan.preview.title"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(preview.pendingIdentifiers.suffix(8).reversed()), id: \.self) { id in
                                    PhotoThumbnail(identifier: id).frame(width: 83, height: 92).clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        Text(L10n.format("scan.preview.sample", min(8, preview.pendingCount).formatted(), preview.pendingCount.formatted()))
                            .lunaFont(11).foregroundStyle(LunaColor.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 9)
                    }
                    LunaSectionLabel(title: L10n.tr("ui.scan.destination"))
                    DestinationCard(model: model, showsStatus: false)
                    if !preview.issues.isEmpty { IssueList(issues: preview.issues, showsPhotos: true).padding(.top, 20) }
                } else {
                    Text(L10n.tr("copy.b477db02")).lunaFont(13).foregroundStyle(LunaColor.muted).padding(.top, 40)
                    Button(L10n.tr("copy.77a40a52")) { Task { await model.scanPreview() } }.frame(minHeight: 44).padding(.top, 14)
                }
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                LunaBottomAction {
                    LunaButton(title: L10n.tr("copy.a9a6b694"), disabled: model.scanning || model.preview == nil || model.preview?.pendingCount == 0 || model.destinationNeedsReconnect, action: start)
                }
            }
            .interactiveDismissDisabled(model.scanning)
            .task(id: model.canStart) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--design-fixture") { return }
                #endif
                guard model.canStart else { return }
                await model.scanPreview()
            }
            .fullScreenCover(isPresented: $showingScope, onDismiss: { Task { await model.scanPreview() } }) { PhotoScopeSheet(model: model) }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack { Text(title); Spacer(); Text(count.formatted()).fontWeight(.semibold).monospacedDigit() }.lunaFont(13)
    }
}

struct TransferView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    let showFiles: () -> Void
    private var finished: Bool { model.runState == .completed && !model.busy }
    private var paused: Bool { !model.busy && (model.runState == .paused || model.runState == .failed) }
    private var progress: Double { Double(model.completed) / Double(max(1, model.total)) }
    var body: some View {
        ScrollView {
            Group {
                if finished { completePage }
                else if paused { pausedPage }
                else { activePage }
            }.lunaPage()
        }.background(LunaColor.paper)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                LunaBottomAction {
                    if model.busy {
                        LunaButton(title: L10n.tr("copy.8fa0fb0b"), icon: "pause", secondary: true) { model.pause() }
                        Text(L10n.tr("design.transfer.footer")).lunaFont(10).foregroundStyle(LunaColor.muted)
                    } else if finished && model.issues.isEmpty {
                        LunaButton(title: L10n.tr("copy.0baeadcf"), icon: "arrow.right", action: showFiles)
                        Button(L10n.tr("copy.d417d3d5")) { dismiss() }.lunaFont(13).frame(minHeight: 44)
                    } else {
                        LunaButton(title: paused ? L10n.tr("copy.6abd292d") : L10n.tr("copy.500e0ff0"), icon: "play",
                            disabled: model.destinationNeedsReconnect || model.connecting) { model.start() }
                        Button(L10n.tr("copy.1184a1eb")) { dismiss() }.lunaFont(13).frame(minHeight: 44)
                    }
                }
            }
    }

    private var activePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            LunaHeader(title: L10n.tr("ui.transfer.title"), back: { dismiss() }).padding(.bottom, 28)
            PageIntro(title: L10n.tr("ui.transfer.heading"), detail: model.transferInstructions)
            Group {
                if let id = model.activePhotoID { PhotoThumbnail(identifier: id, size: 360) }
                else {
                    LunaColor.panel.overlay { Image(systemName: "photo.stack").lunaFont(30, weight: .light).foregroundStyle(LunaColor.muted) }
                }
            }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: LunaLayout.cardRadius)).padding(.top, 24)
            HStack {
                Text(model.total > 0 ? L10n.format("copy.91c3704b", model.completed.formatted(), model.total.formatted()) : model.status)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                if model.total > 0 { Text(progress.formatted(.percent.precision(.fractionLength(0)))).foregroundStyle(LunaColor.accent).monospacedDigit() }
            }.lunaFont(12).padding(.top, 22).padding(.bottom, 10)
            progressBar
            HStack(spacing: 12) {
                Image(systemName: "photo").lunaFont(19).foregroundStyle(LunaColor.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.currentFile.isEmpty ? model.status : model.currentFile).lunaFont(13, weight: .medium)
                        .lineLimit(2).truncationMode(.middle)
                    if model.currentBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.currentBytes), countStyle: .file))
                            .lunaFont(11).foregroundStyle(LunaColor.muted)
                    }
                }
                Spacer(minLength: 0)
            }.padding(18).frame(minHeight: 77).lunaSurface().padding(.top, 20)
            Label(L10n.tr("design.transfer.recorded"), systemImage: "checkmark")
                .lunaFont(11).foregroundStyle(LunaColor.muted).padding(.top, 18)
        }
    }

    private var completePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            LunaHeader(title: L10n.tr("ui.complete.result"), back: { dismiss() })
            VStack(spacing: 16) {
                LunaStatusEmblem(symbol: model.issues.isEmpty ? "heart.fill" : "exclamationmark.triangle",
                                 color: model.issues.isEmpty ? LunaColor.success : LunaColor.warning)
                Text(L10n.tr(!model.issues.isEmpty ? "copy.478682ec" : model.completed == model.initialCompleted ? "ui.home.current" : "ui.complete.title"))
                    .lunaFont(24, weight: .semibold, relativeTo: .title2).multilineTextAlignment(.center)
                Text(L10n.tr(model.issues.isEmpty ? "ui.complete.body" : "family.complete.partial"))
                    .lunaFont(13).foregroundStyle(LunaColor.muted).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.top, 48).padding(.bottom, 32)
            LunaStatPair(firstTitle: L10n.tr("ui.complete.saved"), firstValue: max(0, model.completed - model.initialCompleted).formatted(),
                         secondTitle: L10n.tr("ui.complete.skipped"), secondValue: model.initialCompleted.formatted(), accentSecond: false)
            if !model.sessionPhotoIDs.isEmpty {
                LunaSectionLabel(title: L10n.tr("ui.complete.recent"))
                HStack(spacing: 8) {
                    ForEach(Array(model.sessionPhotoIDs.suffix(4)), id: \.self) { id in
                        PhotoThumbnail(identifier: id).frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if model.issues.isEmpty {
                Label(L10n.tr("design.complete.verified"), systemImage: "checkmark.shield")
                    .lunaFont(12).foregroundStyle(LunaColor.success).padding(.top, 22)
            } else { IssueList(issues: model.issues).padding(.top, 22) }
        }
    }

    private var pausedPage: some View {
        let failed = model.runState == .failed
        return VStack(alignment: .leading, spacing: 0) {
            LunaHeader(title: L10n.tr(failed ? "copy.478682ec" : "copy.4e8fd14b"), back: { dismiss() })
            VStack(spacing: 16) {
                LunaStatusEmblem(symbol: failed ? "exclamationmark.triangle" : "pause", color: failed ? LunaColor.warning : LunaColor.accent)
                Text(L10n.tr(failed ? "ui.errors.title" : "ui.paused.title"))
                    .lunaFont(24, weight: .semibold, relativeTo: .title2).multilineTextAlignment(.center)
                Text(model.backgroundPauseReason ?? L10n.tr("design.paused.body"))
                    .lunaFont(13).foregroundStyle(LunaColor.muted).lineSpacing(4).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.top, 40).padding(.bottom, 30)
            LunaStatPair(firstTitle: L10n.tr("ui.home.saved"), firstValue: model.completed.formatted(),
                         secondTitle: L10n.tr("ui.paused.remaining"), secondValue: max(0, model.total - model.completed).formatted())
            LunaSectionLabel(title: L10n.tr("family.destination.label"))
            DestinationCard(model: model, showsStatus: false)
            if model.destinationNeedsReconnect {
                Text(L10n.tr("destination.unavailable.message")).lunaFont(12).foregroundStyle(LunaColor.muted).padding(.top, 12)
            }
            if !model.issues.isEmpty { IssueList(issues: model.issues).padding(.top, 18) }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(LunaColor.border)
                Capsule().fill(LunaColor.accent).frame(width: geometry.size.width * min(1, progress))
            }
        }.frame(height: 5)
    }

    private func checkRow(_ title: String) -> some View {
        HStack {
            Text(title).lunaFont(12)
            Spacer(); Image(systemName: "checkmark").lunaFont(14).foregroundStyle(LunaColor.success)
        }.padding(.vertical, 15)
    }
}

struct IssueList: View {
    let issues: [String: String]
    var showsPhotos = false
    private var groups: [(reason: String, identifiers: [String])] {
        Dictionary(grouping: issues.keys, by: { issues[$0] ?? "" })
            .map { (reason: $0.key, identifiers: $0.value.sorted()) }
            .sorted { $0.reason < $1.reason }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format("issues.title.count", issues.count.formatted()))
                .lunaFont(13, weight: .semibold)
            if showsPhotos {
                Text(L10n.tr("issues.scan.explanation")).lunaFont(12).foregroundStyle(LunaColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups, id: \.reason) { group in
                Group {
                    if showsPhotos {
                        DisclosureGroup {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(group.identifiers, id: \.self) { identifier in
                                    IssuePhotoRow(identifier: identifier)
                                }
                            }.padding(.top, 12)
                        } label: {
                            groupSummary(reason: group.reason, count: group.identifiers.count)
                        }
                    } else {
                        groupSummary(reason: group.reason, count: group.identifiers.count)
                    }
                }.tint(LunaColor.warning).padding(15)
                    .background(LunaColor.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func groupSummary(reason: String, count: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").lunaFont(17)
            VStack(alignment: .leading, spacing: 5) {
                Text(reason).lunaFont(12).lineSpacing(4)
                Text(L10n.format(showsPhotos ? "issues.group.count" : "issues.group.total", count.formatted())).font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(LunaColor.warning)
    }

}

private struct IssuePhotoRow: View {
    let identifier: String
    @State private var name = ""
    @State private var date = ""
    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(identifier: identifier, size: 56)
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(name.isEmpty ? L10n.tr("issues.photo.unavailable") : name).font(.subheadline).lineLimit(2)
                if !date.isEmpty { Text(date).font(.caption).foregroundStyle(LunaColor.muted) }
            }
        }.task(id: identifier) {
            let details = await Task.detached(priority: .utility) { () -> (String, String) in
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return ("", "") }
                let resources = PHAssetResource.assetResources(for: asset)
                return (resources.first?.originalFilename ?? "", asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }.value
            guard !Task.isCancelled else { return }
            name = details.0; date = details.1
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: BackupModel
    var close: (() -> Void)? = nil
    private var months: [Date] {
        Array(Set(model.diskHistory.compactMap { Calendar.current.dateInterval(of: .month, for: $0.finishedAt)?.start })).sorted(by: >)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LunaHeader(title: L10n.tr("copy.68528842")).padding(.bottom, 14)
                Text(L10n.tr("ui.history.body")).lunaFont(13).foregroundStyle(LunaColor.muted).padding(.bottom, 12)
                if model.archive == nil {
                    quietEmpty(L10n.tr("copy.06014aca"), symbol: "externaldrive")
                } else {
                    ForEach(months, id: \.self) { month in
                        LunaEyebrow(title: month.formatted(.dateTime.year().month(.wide)).uppercased()).padding(.top, 20).padding(.bottom, 10)
                        ForEach(model.diskHistory.filter { Calendar.current.isDate($0.finishedAt, equalTo: month, toGranularity: .month) }) { session in
                            NavigationLink {
                                HistoryDetailView(session: session)
                            } label: {
                                HStack(spacing: 13) {
                                    historyThumbnail(session).frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.finishedAt.formatted(.dateTime.month().day().hour().minute())).lunaFont(12, weight: .semibold)
                                        Text(L10n.format("design.history.count", session.completed.formatted(), session.total.formatted()))
                                            .lunaFont(10).foregroundStyle(LunaColor.muted)
                                    }
                                    Spacer()
                                    Image(systemName: session.issues.isEmpty ? "checkmark" : "exclamationmark.circle")
                                        .lunaFont(15).foregroundStyle(session.issues.isEmpty ? LunaColor.success : LunaColor.warning)
                                }.padding(12).frame(minHeight: LunaLayout.rowHeight).lunaSurface()
                            }.buttonStyle(.plain).padding(.bottom, 12)
                        }
                    }
                    if model.diskHistory.isEmpty { quietEmpty(L10n.tr("copy.d0247b21"), symbol: "clock.arrow.circlepath") }
                    NavigationLink { ArchiveRecordsView(model: model) } label: {
                        HStack {
                            Text(L10n.tr("copy.5402d85b")); Spacer(); Image(systemName: "chevron.right")
                        }.lunaFont(12).foregroundStyle(LunaColor.muted).padding(.vertical, 22)
                    }
                }
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func historyThumbnail(_ session: SessionSummary) -> some View {
        let id = model.historyPhotoIDs[session.id]
        if let id { PhotoThumbnail(identifier: id) }
        else { LunaColor.panel.overlay { Image(systemName: "photo").foregroundStyle(LunaColor.muted) } }
    }

    private func quietEmpty(_ title: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).lunaFont(34, weight: .light)
            Text(title).lunaFont(12).lineSpacing(6).multilineTextAlignment(.center)
        }.foregroundStyle(LunaColor.muted).frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

struct HistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let session: SessionSummary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LunaHeader(title: L10n.tr("copy.100bb14a"), back: { dismiss() })
                PageIntro(title: session.finishedAt.formatted(date: .abbreviated, time: .shortened), detail: session.status)
                DetailRow(title: L10n.tr("copy.f2e4d5e9"), value: "\(session.completed) / \(session.total)")
                IssueList(issues: session.issues)
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
    }
}

struct ArchiveRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LunaHeader(title: L10n.tr("copy.ec8ba6cf"), back: { dismiss() })
                ForEach(model.archiveRecords, id: \.assetKey) { record in
                    ForEach(record.generations, id: \.id) { generation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(generation.asset.resources.first?.originalFilename ?? record.localIdentifier).lunaFont(12, weight: .medium)
                            Text(generation.isComplete ? L10n.tr("copy.78c2e501") : L10n.tr("copy.f438b277")).lunaFont(11)
                                .foregroundStyle(generation.isComplete ? LunaColor.success : LunaColor.warning)
                            ForEach(generation.resources.keys.sorted(), id: \.self) { key in
                                if let receipt = generation.resources[key] {
                                    Text(receipt.relativePath).lunaFont(10).foregroundStyle(LunaColor.muted).textSelection(.enabled)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
    }
}

struct IntegrityView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    @State private var showingIssues = false
    private var hasIssues: Bool { model.verification?.issues.isEmpty == false }
    private var summaryTitle: String {
        if model.isVerifying { return L10n.tr("copy.32bb566e") }
        guard model.verification != nil else { return L10n.tr("ui.integrity.unchecked") }
        return L10n.tr(hasIssues ? "ui.integrity.attention" : "ui.integrity.normal")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LunaHeader(title: L10n.tr("copy.4dfa705d"), back: { dismiss() })
                VStack(spacing: 16) {
                    LunaStatusEmblem(symbol: model.verification == nil ? "shield" : hasIssues ? "exclamationmark.shield" : "checkmark.shield",
                                     color: model.verification == nil ? LunaColor.muted : hasIssues ? LunaColor.warning : LunaColor.success)
                    Text(summaryTitle).lunaFont(23, weight: .semibold, relativeTo: .title2).multilineTextAlignment(.center)
                    if model.isVerifying {
                        ProgressView().tint(LunaColor.accent)
                        Text(model.status).lunaFont(12).foregroundStyle(LunaColor.muted)
                    } else {
                        Text(model.verificationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L10n.tr("ui.integrity.start"))
                            .lunaFont(12).foregroundStyle(LunaColor.muted).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity).padding(.top, 44).padding(.bottom, 30)
                LunaStatPair(firstTitle: L10n.tr("ui.integrity.checked"), firstValue: model.verification?.checked.formatted() ?? "—",
                             secondTitle: L10n.tr("ui.integrity.issues"), secondValue: model.verification?.issues.count.formatted() ?? "—", accentSecond: hasIssues)
                if let result = model.verification, !result.issues.isEmpty {
                    Button { showingIssues = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.format("design.integrity.issues", result.issues.count.formatted())).lunaFont(13, weight: .semibold)
                                Text(L10n.tr("design.integrity.repair.body")).lunaFont(12)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                        }.foregroundStyle(LunaColor.warning).padding(16).frame(minHeight: 77)
                            .background(LunaColor.accentTint, in: RoundedRectangle(cornerRadius: LunaLayout.cardRadius))
                    }.buttonStyle(.plain).padding(.top, 16)
                }
                LunaSectionLabel(title: L10n.tr("integrity.explanation.title"))
                Text(L10n.tr("integrity.explanation.body"))
                    .lunaFont(13).foregroundStyle(LunaColor.muted).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18).lunaSurface()
            }.lunaPage()
        }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                LunaBottomAction {
                    LunaButton(title: model.isVerifying ? L10n.tr("copy.4b69ec6c") : L10n.tr("copy.f91515e1"), secondary: true,
                        disabled: model.archive == nil || model.destinationNeedsReconnect || (model.busy && !model.isVerifying)) {
                        if model.isVerifying { model.pause() } else { model.verify() }
                    }
                }
            }
            .navigationDestination(isPresented: $showingIssues) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LunaHeader(title: L10n.tr("copy.d53d1714"), back: { showingIssues = false })
                        ForEach(model.verification?.issues ?? [], id: \.self) {
                            Text($0).lunaFont(13).foregroundStyle(LunaColor.warning).lineSpacing(5)
                        }
                        Text(L10n.tr("copy.4fb252ea")).lunaFont(12).foregroundStyle(LunaColor.muted).lineSpacing(5)
                    }.lunaPage()
                }.background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
            }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    @State private var showingDirectory = false
    @State private var showingStorageDetails = false
    private var locked: Bool { model.busy || model.scanning || model.connecting }
    private var reviewBottom: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--review-settings-bottom")
        #else
        return false
        #endif
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LunaHeader(title: L10n.tr("copy.f3c259dd"), back: { dismiss() })
                section(L10n.tr("copy.66de7686"), top: 24)
                Button { showingDirectory = true } label: { DestinationCard(model: model, showsStatus: false) }.buttonStyle(.plain).disabled(locked)
                Text(L10n.tr("design.settings.drives")).lunaFont(12).foregroundStyle(LunaColor.muted).lineSpacing(4).padding(.top, 10)
                DisclosureGroup(isExpanded: $showingStorageDetails) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.tr("copy.3770d50c")).lunaFont(12).foregroundStyle(LunaColor.muted).lineSpacing(5)
                        Text(L10n.tr("storage.flat.example")).lunaFont(12, design: .monospaced)
                            .lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).background(LunaColor.panel, in: RoundedRectangle(cornerRadius: 12))
                    }.padding(.top, 8).padding(.bottom, 4)
                } label: {
                    Text(L10n.tr("settings.storage.explanation")).lunaFont(12).frame(minHeight: 44)
                }.tint(LunaColor.muted).padding(.horizontal, 4)
                section(L10n.tr("copy.1c1e102f"), top: 26)
                VStack(spacing: 0) {
                    toggleRow(L10n.tr("design.settings.originals"), symbol: "photo", value: .constant(true), permanent: true)
                    Divider().overlay(LunaColor.divider)
                    toggleRow(L10n.tr("copy.cc1554cc"), symbol: "play", value: Binding(get: { model.includeVideos }, set: { model.includeVideos = $0; model.clearPhotoSelection() }))
                    Divider().overlay(LunaColor.divider)
                    toggleRow(L10n.tr("design.settings.icloud"), symbol: "icloud", value: $model.allowNetwork)
                    Divider().overlay(LunaColor.divider)
                    toggleRow(L10n.tr("design.settings.verify"), symbol: "checkmark.shield", value: .constant(true), permanent: true)
                }.padding(.horizontal, 16).lunaSurface()
                section(L10n.tr("settings.maintenance.title"), top: 26)
                NavigationLink { IntegrityView(model: model) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield").font(.system(size: 21)).foregroundStyle(LunaColor.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.tr("copy.4dfa705d")).lunaFont(14, weight: .semibold)
                            Text(L10n.tr("settings.maintenance.verify.detail")).lunaFont(12).foregroundStyle(LunaColor.muted)
                        }.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(LunaColor.muted)
                    }.foregroundStyle(LunaColor.ink).padding(16).frame(minHeight: LunaLayout.rowHeight).lunaSurface()
                }.buttonStyle(.plain)
                section(L10n.tr("settings.system.section"), top: 26)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape").font(.system(size: 21)).foregroundStyle(LunaColor.muted)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.tr("settings.system.title")).lunaFont(14, weight: .semibold)
                            Text(L10n.tr("settings.system.detail")).lunaFont(12).foregroundStyle(LunaColor.muted)
                        }.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward").font(.system(size: 14)).foregroundStyle(LunaColor.muted)
                    }.foregroundStyle(LunaColor.ink).padding(16).frame(minHeight: LunaLayout.rowHeight).lunaSurface()
                }.buttonStyle(.plain)
            }.lunaPage()
        }.defaultScrollAnchor(reviewBottom ? .bottom : .top)
            .background(LunaColor.paper).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingDirectory) { DirectoryPicker(initialURL: model.archiveURL) { model.selectDirectory($0) } }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--review-storage-details") { showingStorageDetails = true }
            }
            #endif
    }
    private func section(_ title: String, top: CGFloat) -> some View {
        Text(title).lunaFont(13, weight: .semibold).padding(.top, top).padding(.bottom, 12)
    }
    private func toggleRow(_ title: String, symbol: String, value: Binding<Bool>, permanent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(width: 18)
            Text(title).lunaFont(12, weight: .medium)
            Spacer()
            if permanent {
                Text(L10n.tr("ui.settings.always")).lunaFont(11).foregroundStyle(LunaColor.muted)
            } else { LunaSwitch(value: value, locked: locked).accessibilityLabel(title) }
        }.padding(.vertical, 8).frame(minHeight: 62)
    }
}

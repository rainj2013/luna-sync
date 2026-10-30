import SwiftUI
import Photos
import ZLPhotoBrowser
import LunaSyncPhotoKit
import LunaSyncCore

struct PhotoScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    @State private var showingDates = false
    @State private var showingManual = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("scope.intro")).font(.title2.weight(.semibold))
                        Text(L10n.tr("scope.current") + model.selectionSummary)
                            .font(.subheadline).foregroundStyle(LunaColor.muted)
                    }
                    VStack(spacing: 12) {
                        Button { model.useDateFilter(.all); dismiss() } label: {
                            methodRow(title: L10n.tr("copy.f7e5f13b"), detail: L10n.tr("scope.all.detail"),
                                      icon: "photo.stack", selected: model.selectedPhotoIDs == nil && model.dateFilter == .all, disclosure: false)
                        }.buttonStyle(.plain)
                        Button { showingDates = true } label: {
                            methodRow(title: L10n.tr("scope.dates.title"), detail: L10n.tr("scope.dates.detail"),
                                      icon: "calendar", selected: model.selectedPhotoIDs == nil && model.dateFilter != .all)
                        }.buttonStyle(.plain)
                        Button { showingManual = true } label: {
                            methodRow(title: L10n.tr("scope.manual.title"), detail: L10n.tr("scope.manual.detail"),
                                      icon: "checkmark.circle", selected: model.selectedPhotoIDs != nil)
                        }.buttonStyle(.plain)
                    }
                    if model.limitedAccess {
                        Label(L10n.tr("scope.limited"), systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(LunaColor.muted)
                    }
                }.padding(24)
            }
            .background(LunaColor.paper)
            .navigationTitle(L10n.tr("copy.15b87fe2"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("directory.cancel")) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showingDates) {
                PhotoDateScopeView(model: model) { dismiss() }
            }
            .navigationDestination(isPresented: $showingManual) {
                ManualPhotoSelectionView(isPresented: $showingManual,
                                         initialSelection: model.selectedPhotoIDs ?? [], includeVideos: model.includeVideos) { identifiers in
                    model.usePhotoSelection(identifiers)
                    dismiss()
                }
            }
            #if DEBUG
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--review-scope-dates") { showingDates = true }
                if arguments.contains("--review-scope-manual") { showingManual = true }
            }
            #endif
        }.foregroundStyle(LunaColor.ink).tint(LunaColor.accent).preferredColorScheme(.light)
    }

    private func methodRow(title: String, detail: String, icon: String, selected: Bool, disclosure: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).lunaFont(22).foregroundStyle(LunaColor.accent)
                .frame(width: 46, height: 46)
                .background(LunaColor.panel, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(LunaColor.ink)
                Text(detail).font(.subheadline).foregroundStyle(LunaColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(LunaColor.accent) }
            if disclosure { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(LunaColor.muted) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: LunaLayout.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: LunaLayout.cardRadius).stroke(selected ? LunaColor.accent.opacity(0.45) : LunaColor.border) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Draft values stay local until confirmation; Back/Cancel never changes the model.
struct PhotoDateScopeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: BackupModel
    let onConfirm: () -> Void
    @State private var filter: PhotoDateFilter
    @State private var start: Date
    @State private var end: Date

    init(model: BackupModel, onConfirm: @escaping () -> Void) {
        self.model = model; self.onConfirm = onConfirm
        #if DEBUG
        let reviewingCustom = ProcessInfo.processInfo.arguments.contains("--review-custom-date")
        _filter = State(initialValue: reviewingCustom ? .custom : (model.dateFilter == .all ? .last30Days : model.dateFilter))
        #else
        _filter = State(initialValue: model.dateFilter == .all ? .last30Days : model.dateFilter)
        #endif
        _start = State(initialValue: min(model.customStart, model.customEnd))
        _end = State(initialValue: max(model.customStart, model.customEnd))
    }

    private var summary: String {
        if filter != .custom { return filter.title }
        let first = L10n.shortDate(start)
        let last = L10n.shortDate(end)
        return first == last ? first : "\(first) – \(last)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.tr("scope.dates.help")).font(.subheadline).foregroundStyle(LunaColor.muted)
                VStack(spacing: 0) {
                    ForEach([PhotoDateFilter.today, .last7Days, .last30Days, .thisYear, .custom]) { value in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { filter = value }
                        } label: {
                            HStack {
                                Text(value.title).foregroundStyle(LunaColor.ink)
                                Spacer()
                                Image(systemName: filter == value ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(filter == value ? LunaColor.accent : LunaColor.border)
                            }.font(.body).padding(16).frame(minHeight: 54).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                        if value != .custom { Divider().padding(.leading, 16) }
                    }
                    if filter == .custom {
                        VStack(spacing: 18) {
                            LunaDateField(title: L10n.tr("copy.5d62764c"), selection: $start, bounds: Date.distantPast...end)
                            LunaDateField(title: L10n.tr("copy.476d405b"), selection: $end, bounds: start...Date.distantFuture)
                        }.font(.subheadline).padding(16).background(LunaColor.panel)
                    }
                }.background(.white, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
            }.padding(24)
        }.background(LunaColor.paper)
            .navigationTitle(L10n.tr("scope.dates.title")).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LunaBottomAction {
                    Text(summary).font(.subheadline).foregroundStyle(LunaColor.muted)
                    LunaButton(title: L10n.tr("scope.confirm")) {
                        if filter == .custom { model.customStart = start; model.customEnd = end }
                        model.useDateFilter(filter)
                        onConfirm()
                    }
                }
            }
    }
}

/// One photo grid, with an optional endpoint mode. Each mode starts a fresh selection.
struct ManualPhotoSelectionView: View {
    @Binding var isPresented: Bool
    let initialSelection: Set<String>
    let includeVideos: Bool
    let onSelect: (Set<String>) -> Void
    @State private var style: ZLPhotoLibraryPicker.SelectionStyle = .individual

    var body: some View {
        ZLPhotoLibraryPicker(isPresented: $isPresented, initialSelection: initialSelection,
                             includeVideos: includeVideos, selectionStyle: style, hosted: true,
                             onStyleChanged: { style = $0 }, onSelect: onSelect)
            .ignoresSafeArea(.container, edges: .bottom).toolbar(.hidden, for: .navigationBar)
    }
}

/// Lives under the album navigation, and disappears naturally during photo preview.
final class PhotoSelectionModeControl: UIView {
    let control = UISegmentedControl(items: [L10n.tr("scope.manual.individual"), L10n.tr("scope.manual.range")])
    private let hint = UILabel()
    private let onChange: (ZLPhotoLibraryPicker.SelectionStyle) -> Void

    init(style: ZLPhotoLibraryPicker.SelectionStyle, onChange: @escaping (ZLPhotoLibraryPicker.SelectionStyle) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        backgroundColor = UIColor(LunaColor.paper)
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = UIColor(LunaColor.muted)
        hint.numberOfLines = 0
        control.accessibilityLabel = L10n.tr("scope.manual.mode")
        control.addTarget(self, action: #selector(changed), for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [control, hint])
        stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        update(style)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ style: ZLPhotoLibraryPicker.SelectionStyle) {
        control.selectedSegmentIndex = style == .individual ? 0 : 1
        hint.text = L10n.tr(style == .individual ? "scope.manual.individual.help" : "scope.manual.range.help")
        superview?.setNeedsLayout()
    }

    @objc private func changed() { onChange(control.selectedSegmentIndex == 0 ? .individual : .range) }
}


struct ZLPhotoLibraryPicker: UIViewControllerRepresentable {
    enum SelectionStyle: Hashable {
        case individual
        case range
    }

    @Binding var isPresented: Bool
    let initialSelection: Set<String>
    let includeVideos: Bool
    let selectionStyle: SelectionStyle
    var hosted = false
    var onStyleChanged: ((SelectionStyle) -> Void)? = nil
    let onSelect: (Set<String>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: initialSelection) }

    @MainActor final class Coordinator {
        var selectionTask: Task<Void, Never>?
        weak var navigation: ZLImageNavController?
        weak var modeControl: PhotoSelectionModeControl?
        var style: SelectionStyle = .individual
        var range: PhotoRangeSelection
        init(selected: Set<String>) { range = PhotoRangeSelection(selected: selected) }

        func select(_ asset: PHAsset) {
            guard let navigation else { return }
            guard range.anchor != nil else {
                range.select(asset.localIdentifier, orderedIdentifiers: [])
                return
            }
            let fetch = navigation.currentAlbumFetchResult()
            let fallback = fetch == nil ? navigation.currentAlbumAssets() : []
            let previous = range
            selectionTask?.cancel()
            navigation.setSelectionBusy(true)
            selectionTask = Task { @MainActor [weak self, weak navigation] in
                guard let self, let navigation else { return }
                defer { navigation.setSelectionBusy(false) }
                let worker = Task.detached(priority: .userInitiated) {
                    var albumAssets: [PHAsset] = []
                    if let fetch {
                        albumAssets.reserveCapacity(fetch.count)
                        for index in 0..<fetch.count {
                            try Task.checkCancellation()
                            albumAssets.append(fetch.object(at: index))
                        }
                    } else { albumAssets = fallback }
                    let identifiers = albumAssets.map(\.localIdentifier)
                    var updated = previous
                    updated.select(asset.localIdentifier, orderedIdentifiers: identifiers)
                    let selected = updated.selected
                    let assets = albumAssets.filter { selected.contains($0.localIdentifier) }
                        + ZLPhotoLibraryPicker.assets(for: selected.subtracting(Set(identifiers)))
                    return (updated, assets)
                }
                guard let (updated, assets) = try? await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }), !Task.isCancelled else { return }
                await navigation.replaceSelectionInBackground(with: assets)
                if !Task.isCancelled { range = updated }
            }
        }
    }

    func makeUIViewController(context: Context) -> UIViewController {
        ZLPhotoConfiguration.resetConfiguration()
        ZLPhotoUIConfiguration.resetConfiguration()
        let config = ZLPhotoConfiguration.default()
        let uiConfig = ZLPhotoUIConfiguration.default()
        config.maxSelectCount = Int.max
        config.allowSelectImage = true
        config.preloadSelectedOriginalImageData = false
        config.downloadVideoBeforeSelecting = false
        config.allowSelectVideo = includeVideos
        // Backups copy original resources; messaging/editor duration limits do not apply.
        config.maxSelectVideoDuration = .max
        config.minSelectVideoDuration = 0
        config.maxSelectVideoDataSize = .greatestFiniteMagnitude
        config.allowMixSelect = true
        config.allowSlideSelect = selectionStyle == .individual
        config.autoScrollWhenSlideSelectIsActive = selectionStyle == .individual
        config.allowPreviewPhotos = true
        config.showPreviewButtonInAlbum = true
        config.showSelectedIndex = true
        config.allowTakePhotoInLibrary = false
        config.allowEditImage = false
        config.allowEditVideo = false
        config.allowSelectOriginal = false
        uiConfig.columnCount = 4
        uiConfig.minimumInteritemSpacing = 2
        uiConfig.minimumLineSpacing = 2
        uiConfig.showIndexOnSelectBtn = true
        uiConfig.showScrollToBottomBtn = true
        uiConfig.navCancelButtonStyle = .text
        uiConfig.themeColor = UIColor(LunaColor.accent)
        if hosted {
            uiConfig.statusBarStyle = .darkContent
            uiConfig.navBarColor = UIColor(LunaColor.paper)
            uiConfig.navTitleColor = UIColor(LunaColor.ink)
            uiConfig.navEmbedTitleViewBgColor = UIColor(LunaColor.panel)
            uiConfig.thumbnailBgColor = UIColor(LunaColor.paper)
            uiConfig.albumListBgColor = UIColor(LunaColor.paper)
            uiConfig.albumListTitleColor = UIColor(LunaColor.ink)
            uiConfig.albumListCountColor = UIColor(LunaColor.muted)
            uiConfig.separatorColor = UIColor(LunaColor.border)
            uiConfig.bottomToolViewBgColor = UIColor(LunaColor.paper)
            uiConfig.bottomToolViewBtnNormalTitleColor = UIColor(LunaColor.ink)
            uiConfig.navViewBlurEffectOfAlbumList = nil
            uiConfig.bottomViewBlurEffectOfAlbumList = nil
        }
        let coordinator = context.coordinator
        coordinator.style = selectionStyle
        config.didSelectAsset = { [weak coordinator] asset in
            if coordinator?.style == .range { coordinator?.select(asset) }
        }
        config.didDeselectAsset = { [weak coordinator] asset in
            coordinator?.range.deselect(asset.localIdentifier)
        }

        let picker = ZLPhotoPicker(selectedAssets: [])
        picker.cancelBlock = {
            DispatchQueue.main.async { isPresented = false }
        }

        // We only need stable PhotoKit identifiers. Prevent the library from exporting a
        // full-resolution UIImage for every selected asset, which would be wasteful for backups.
        config.operateBeforeDoneAction = { controller, selectedModels, continueBlock in
            if coordinator.style == .range, coordinator.range.anchor != nil {
                let alert = UIAlertController(title: L10n.tr("copy.a7c0df4a"),
                                              message: L10n.tr("copy.a701e774"),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.tr("copy.3f002393"), style: .default))
                controller.present(alert, animated: true)
                continueBlock(false)
                return
            }
            let identifiers = Set(selectedModels.map { $0.asset.localIdentifier })
            DispatchQueue.main.async {
                onSelect(identifiers)
                isPresented = false
            }
            continueBlock(false)
        }

        let navigation = picker.showPhotoLibraryForSwiftUI()
        coordinator.navigation = navigation
        navigation.handlesCancellationInHost = hosted
        if hosted {
            let modes = PhotoSelectionModeControl(style: selectionStyle) { onStyleChanged?($0) }
            coordinator.modeControl = modes
            navigation.selectionAccessoryView = modes
            navigation.selectionBusyChanged = { [weak modes] busy in modes?.control.isEnabled = !busy }
        }
        if !initialSelection.isEmpty {
            navigation.setSelectionBusy(true)
            coordinator.selectionTask = Task { @MainActor [weak navigation] in
                guard let navigation else { return }
                defer { navigation.setSelectionBusy(false) }
                let identifiers = initialSelection
                let worker = Task.detached(priority: .userInitiated) { Self.assets(for: identifiers) }
                let assets = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                await navigation.replaceSelectionInBackground(with: assets)
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--review-range") {
            Task { @MainActor [weak navigation, weak coordinator] in
                try? await Task.sleep(for: .seconds(1))
                guard let navigation, let coordinator else { return }
                let assets = navigation.currentAlbumAssets()
                guard assets.count >= 8 else { return }
                let first = assets[assets.count - 8], last = assets[assets.count - 3]
                navigation.replaceSelection(with: [first])
                coordinator.select(first)
                coordinator.select(last)
            }
        }
        #endif
        return navigation
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.style != selectionStyle else { return }
        coordinator.selectionTask?.cancel()
        coordinator.range = PhotoRangeSelection()
        coordinator.navigation?.replaceSelection(with: [])
        coordinator.style = selectionStyle
        coordinator.modeControl?.update(selectionStyle)
        ZLPhotoConfiguration.default().allowSlideSelect = selectionStyle == .individual
        ZLPhotoConfiguration.default().autoScrollWhenSlideSelectIsActive = selectionStyle == .individual
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.selectionTask?.cancel()
    }

    nonisolated private static func assets(for identifiers: Set<String>) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        for index in 0..<result.count {
            if Task.isCancelled { break }
            assets.append(result.object(at: index))
        }
        return assets
    }

}


struct SourceChoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BackupModel
    var body: some View {
        NavigationStack {
            ZStack {
                LunaBackdrop()
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tr("copy.8c92c1a2"))
                        .foregroundStyle(.secondary)
                    ForEach(model.archive?.sources ?? []) { source in
                        Button { model.chooseSource(source.id); dismiss() } label: {
                            HStack { Image(systemName: "iphone"); VStack(alignment: .leading) { Text(L10n.tr("copy.1d657a58")).bold(); Text(source.name).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }.lunaCard()
                        }.buttonStyle(.plain)
                    }
                    Button { Task { await model.createSource(); if model.selectedSource != nil { dismiss() } } } label: {
                        HStack { Image(systemName: "plus.circle.fill"); VStack(alignment: .leading) { Text(L10n.tr("copy.e19f8e08")).bold(); Text(L10n.tr("copy.b26c086f")).font(.caption).foregroundStyle(.secondary) }; Spacer() }.lunaCard()
                    }.buttonStyle(.plain)
                    Spacer()
                }.padding(20).disabled(model.busy || model.connecting)
            }.navigationTitle(L10n.tr("copy.e9575b53")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("copy.949856b3")) { dismiss() } } }
        }
    }
}



import SwiftUI
import Photos

enum LunaColor {
    static let paper = Color(hex: 0xFCF8F2)
    static let surface = Color.white
    static let panel = Color(hex: 0xF4ECE1)
    static let subtlePanel = Color(hex: 0xF8F1EA)
    static let ink = Color(hex: 0x3F3530)
    // Slightly stronger than the draft's muted color for small-text contrast.
    static let muted = Color(hex: 0x756960)
    static let border = Color(hex: 0xE7D8CB)
    static let divider = Color(hex: 0xEDE6DE)
    static let accent = Color(hex: 0x98543F)
    static let dark = Color(hex: 0x844631)
    static let accentTint = Color(hex: 0xF7E9E0)
    static let disabled = Color(hex: 0xE7D6CD)
    static let success = Color(hex: 0x526C59)
    static let sage = Color(hex: 0xDCE5D7)
    static let warning = Color(hex: 0x946127)
    static let error = Color(hex: 0xAC5042)
    static let blush = Color(hex: 0xF4DACA)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

enum LunaLayout {
    static let pageInset: CGFloat = 24
    static let rowGap: CGFloat = 12
    static let buttonHeight: CGFloat = 54
    static let rowHeight: CGFloat = 77
    static let cardRadius: CGFloat = 19
    static let heroRadius: CGFloat = 27
    static let buttonRadius: CGFloat = 17
}

private struct LunaScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight; self.design = design
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func lunaFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                  relativeTo: Font.TextStyle = .body) -> some View {
        modifier(LunaScaledFont(size: size, weight: weight, design: design, relativeTo: relativeTo))
    }
    func lunaSurface() -> some View {
        background(LunaColor.surface, in: RoundedRectangle(cornerRadius: LunaLayout.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: LunaLayout.cardRadius).stroke(LunaColor.divider, lineWidth: 1) }
    }
}

struct LunaBackdrop: View {
    var body: some View { LunaColor.paper.ignoresSafeArea() }
}

extension View {
    func lunaCard() -> some View {
        padding(18).lunaSurface()
    }
    func lunaPage() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LunaLayout.pageInset).padding(.top, 12).padding(.bottom, 24)
    }
}

struct LunaButton: View {
    let title: String
    var icon: String? = nil
    var secondary = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                if let icon { Image(systemName: icon) }
            }
            .lunaFont(16, weight: .semibold)
            .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity).frame(minHeight: LunaLayout.buttonHeight)
            .foregroundStyle(secondary ? LunaColor.ink : .white)
            .background(disabled ? LunaColor.disabled : secondary ? LunaColor.panel : LunaColor.accent,
                        in: RoundedRectangle(cornerRadius: LunaLayout.buttonRadius))
        }.buttonStyle(.plain).disabled(disabled)
    }
}

struct PageIntro: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).lunaFont(24, weight: .semibold, relativeTo: .title2).tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail).lunaFont(13).foregroundStyle(LunaColor.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusPill: View {
    let title: String
    var warning = false
    var neutral = false
    var body: some View {
        Text(title).lunaFont(11, weight: .medium)
            .foregroundStyle(neutral ? LunaColor.muted : warning ? LunaColor.warning : LunaColor.success)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(neutral ? LunaColor.subtlePanel : warning ? LunaColor.accentTint : LunaColor.sage, in: Capsule())
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(LunaColor.muted)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }.lunaFont(13).padding(.vertical, 7)
    }
}

/// Both endpoints use the same tappable width; the calendar stays native and localized.
struct LunaDateField: View {
    let title: String
    @Binding var selection: Date
    var bounds: ClosedRange<Date> = Date.distantPast...Date.distantFuture
    @State private var showingCalendar = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(LunaColor.ink)
            Spacer(minLength: 0)
            Button { showingCalendar = true } label: {
                HStack(spacing: 8) {
                    Text(L10n.shortDate(selection))
                        .lunaFont(14, weight: .medium)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(LunaColor.accent)
                }.padding(.horizontal, 12).frame(width: 184).frame(minHeight: 44)
                    .foregroundStyle(LunaColor.ink)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(LunaColor.border) }
            }.buttonStyle(.plain).accessibilityLabel(title)
                .accessibilityValue(selection.formatted(date: .complete, time: .omitted))
                .popover(isPresented: $showingCalendar, arrowEdge: .top) {
                    DatePicker(title, selection: $selection, in: bounds, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().tint(LunaColor.accent)
                        .padding(12).frame(width: 320)
                        .presentationCompactAdaptation(.popover)
                        .onChange(of: selection) { _, _ in showingCalendar = false }
                }
        }
    }
}

struct PhotoThumbnail: View {
    let identifier: String
    var size: CGFloat = 110
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LunaColor.panel
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else { Image(systemName: "photo").foregroundStyle(LunaColor.muted) }
            }
        }
        .clipped()
        .task(id: identifier) {
            image = nil
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--design-fixture"), identifier.hasPrefix("ui-review-") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("UI Review Photos")
                    .appendingPathComponent(String(identifier.dropFirst("ui-review-".count)))
                image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
                return
            }
            #endif
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            request = PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: size * scale, height: size * scale),
                contentMode: .aspectFill, options: options) { result, info in
                    guard info?[PHImageCancelledKey] as? Bool != true else { return }
                    Task { @MainActor in if let result { image = result } }
                }
        }
        .onDisappear { if let request { PHImageManager.default().cancelImageRequest(request) } }
    }
}


struct LunaHeader: View {
    var title = ""
    var back: (() -> Void)? = nil
    var symbol: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 18))
                        .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                }.accessibilityLabel(L10n.tr("copy.58cbffa7"))
            }
            Text(title).lunaFont(back == nil ? 22 : 18, weight: .semibold, relativeTo: .headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let symbol, let action {
                Button(action: action) {
                    Image(systemName: symbol).font(.system(size: 17))
                        .frame(width: 38, height: 38).background(.white, in: Circle())
                        .overlay { Circle().stroke(LunaColor.border, lineWidth: 1) }
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel(symbol == "gearshape" ? L10n.tr("copy.f3c259dd") : symbol == "magnifyingglass" ? L10n.tr("files.search") : symbol == "xmark" ? L10n.tr("copy.d417d3d5") : L10n.tr("copy.39b523bd"))
            }
        }.foregroundStyle(LunaColor.ink).frame(minHeight: 44)
    }
}

struct LunaEyebrow: View {
    let title: String
    var body: some View {
        Text(title).lunaFont(12, weight: .medium).tracking(0.4)
            .foregroundStyle(LunaColor.accent).fixedSize(horizontal: false, vertical: true)
    }
}

struct LunaBottomAction<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 12) { content }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity).background(LunaColor.paper)
    }
}

struct LunaTabBar: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 0) {
            tab(0, symbol: "house", title: L10n.tr("copy.7aff3a77"))
            tab(1, symbol: "clock", title: L10n.tr("copy.2c9d9f0e"))
            tab(2, symbol: "square.grid.2x2", title: L10n.tr("copy.a9392c30"))
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4).background(LunaColor.paper)
            .overlay(alignment: .top) { Rectangle().fill(LunaColor.border).frame(height: 0.5) }
    }
    private func tab(_ index: Int, symbol: String, title: String) -> some View {
        Button { selection = index } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                Text(title).lunaFont(12, weight: selection == index ? .semibold : .regular)
            }.foregroundStyle(selection == index ? LunaColor.accent : LunaColor.muted)
                .frame(maxWidth: .infinity).frame(minHeight: 48)
        }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
    }
}

struct LunaSwitch: View {
    @Binding var value: Bool
    var locked = false
    var body: some View {
        Toggle(isOn: $value) { EmptyView() }.labelsHidden().tint(LunaColor.success)
            .disabled(locked).frame(minHeight: 44)
    }
}

struct LunaSectionLabel: View {
    let title: String
    var body: some View {
        Text(title).lunaFont(12, weight: .medium).foregroundStyle(LunaColor.muted)
            .padding(.top, 22).padding(.bottom, 10)
    }
}

struct LunaStatPair: View {
    let firstTitle: String
    let firstValue: String
    let secondTitle: String
    let secondValue: String
    var accentSecond = true
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            stat(firstTitle, firstValue, color: LunaColor.ink)
            Rectangle().fill(LunaColor.divider).frame(width: 1).frame(maxHeight: .infinity)
            stat(secondTitle, secondValue, color: accentSecond ? LunaColor.accent : LunaColor.ink)
        }.fixedSize(horizontal: false, vertical: true).padding(20).lunaSurface()
    }
    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).lunaFont(12).foregroundStyle(LunaColor.muted).fixedSize(horizontal: false, vertical: true)
            Text(value).lunaFont(24, weight: .semibold, relativeTo: .title2)
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LunaStatusEmblem: View {
    let symbol: String
    var color = LunaColor.success
    var body: some View {
        Image(systemName: symbol).lunaFont(27, weight: .regular).foregroundStyle(color)
            .frame(width: 80, height: 80).background(color.opacity(0.1), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A decorative paper album, not sample photos presented as the user's memories.
struct MemoryAlbumIllustration: View {
    var size: CGFloat = 160
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.12).fill(LunaColor.sage)
                .frame(width: size * 0.78, height: size * 0.94)
                .rotationEffect(.degrees(-12)).offset(x: -size * 0.08, y: size * 0.02)
            VStack(spacing: size * 0.08) {
                RoundedRectangle(cornerRadius: size * 0.07).fill(LunaColor.blush)
                    .overlay {
                        Image(systemName: "heart.fill").font(.system(size: size * 0.27, weight: .light))
                            .foregroundStyle(LunaColor.accent.opacity(0.85))
                    }
                HStack(spacing: size * 0.04) {
                    Capsule().fill(LunaColor.panel).frame(width: size * 0.35, height: size * 0.035)
                    Spacer(minLength: 0)
                    Circle().fill(LunaColor.sage).frame(width: size * 0.07, height: size * 0.07)
                }
            }.padding(size * 0.09).frame(width: size * 0.82, height: size)
                .background(.white, in: RoundedRectangle(cornerRadius: size * 0.1))
                .overlay { RoundedRectangle(cornerRadius: size * 0.1).stroke(LunaColor.border.opacity(0.65)) }
                .rotationEffect(.degrees(7))
                
        }.frame(width: size * 1.1, height: size * 1.15).accessibilityHidden(true)
    }
}

struct DriveIllustration: View {
    var body: some View {
        HStack(spacing: 16) {
            MemoryAlbumIllustration(size: 100)
            Image(systemName: "arrow.right").font(.system(size: 18)).foregroundStyle(LunaColor.muted)
            Image(systemName: "externaldrive.fill").font(.system(size: 34, weight: .regular))
                .foregroundStyle(LunaColor.accent).frame(width: 86, height: 100)
                .background(.white, in: RoundedRectangle(cornerRadius: 22))
                .rotationEffect(.degrees(0))
        }.frame(maxWidth: .infinity).frame(height: 210)
            .background(LunaColor.subtlePanel, in: RoundedRectangle(cornerRadius: LunaLayout.heroRadius))
            .accessibilityHidden(true)
    }
}

#if DEBUG
@MainActor
enum AppReviewCapture {
    static func capture(_ name: String) async {
        guard ProcessInfo.processInfo.arguments.contains("--capture-review") else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let data = image.pngData(), let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            let directory = documents.appendingPathComponent("DesignReview", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        } catch { }
    }
}
#endif

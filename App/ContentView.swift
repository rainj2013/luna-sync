import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LunaSyncPhotoKit

struct ContentView: View {
    @ObservedObject var model: BackupModel
    @State private var showingPicker = false

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("移动硬盘") {
                        Label(model.archive.map { "档案 · \($0.archiveID.uuidString.prefix(8))" } ?? "尚未连接", systemImage: "externaldrive")
                        Button("选择备份目录") { showingPicker = true }.disabled(model.busy)
                        if let archive = model.archive {
                            Menu {
                                ForEach(archive.sources) { source in
                                    Button(source.name) { model.chooseSource(source.id) }
                                }
                                Divider()
                                Button("作为新照片库备份") { model.createSource() }
                            } label: {
                                LabeledContent("照片库", value: archive.sources.first(where: { $0.id == model.selectedSource })?.name ?? "请选择")
                            }.disabled(model.busy)
                        }
                    }
                    if model.limitedAccess {
                        Section { Label("仅备份已授权照片，无法代表整个照片库。", systemImage: "photo.badge.exclamationmark") }
                    }
                    Section("备份状态") {
                        Text(model.status).accessibilityAddTraits(.updatesFrequently)
                        HStack {
                            metric("本轮资产", value: model.total)
                            Spacer(); metric("已完成", value: model.completed)
                            Spacer(); metric("待处理", value: max(0, model.total-model.completed))
                        }
                        if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)) }
                        if !model.currentFile.isEmpty {
                            Text(model.currentFile).font(.footnote).lineLimit(2)
                            Text("当前资源已接收 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.currentBytes), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !model.cloudAssets.isEmpty { Text("\(model.cloudAssets.count) 张需要从 iCloud 下载原片").foregroundStyle(.secondary) }
                        if model.busy {
                            Button("暂停", role: .destructive) { model.pause() }
                        } else {
                            Button(model.issues.isEmpty ? "开始增量备份 / 继续" : "重新扫描并重试待处理项") { model.start() }
                                .disabled(model.selectedSource == nil)
                        }
                    }
                    Section {
                        Text("保存未编辑原片，包含 Live Photo 配套视频。中断后未完成的单个文件会重新传输。")
                        Text("手机删除照片不会删除硬盘文件。完成后请妥善断开硬盘。")
                    }.font(.footnote).foregroundStyle(.secondary)
                }.navigationTitle("Luna Sync")
            }.tabItem { Label("备份", systemImage: "externaldrive.badge.plus") }

            NavigationStack {
                List {
                    Section {
                        Button("完整校验已记录文件") { model.verify() }.disabled(model.archive == nil || model.busy)
                        Text("逐文件读取并比对 SHA-256，可能需要较长时间。校验失败的当前原片会在下次备份时重传。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !model.issues.isEmpty {
                        Section("本轮待处理") {
                            ForEach(model.issues.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key).font(.caption).lineLimit(1)
                                    Text(model.issues[key] ?? "").font(.callout)
                                }
                            }
                        }
                    }
                    Section("本机运行历史") {
                        ForEach(model.history) { session in
                            NavigationLink {
                                List {
                                    LabeledContent("结果", value: session.status)
                                    LabeledContent("已完成 / 本轮总数", value: "\(session.completed) / \(session.total)")
                                    Text("档案：\(session.archiveID.uuidString)").font(.caption)
                                    ForEach(session.issues.keys.sorted(), id: \.self) { key in
                                        VStack(alignment: .leading) { Text(key).font(.caption); Text(session.issues[key] ?? "") }
                                    }
                                }.navigationTitle("运行详情")
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(session.status)
                                    Text(session.finishedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                    Text("\(session.completed) / \(session.total) 张已完成").font(.caption)
                                }
                            }
                        }
                        if model.history.isEmpty { Text("暂无运行记录").foregroundStyle(.secondary) }
                    }
                }.navigationTitle("记录与校验")
            }.tabItem { Label("记录", systemImage: "checkmark.shield") }

            NavigationStack {
                Form {
                    Section("原始资源") {
                        Toggle("包含视频", isOn: $model.includeVideos)
                        Toggle("允许从 iCloud 下载原片", isOn: $model.allowNetwork)
                        Text("默认只备份本地原片。开启后由系统从你的 iCloud 下载，不会上传照片到第三方。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(model.busy)
                    Section("目录与权限") {
                        Button("重新选择硬盘目录") { showingPicker = true }.disabled(model.busy)
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        Text("重新安装后，选择原 LunaSync 目录并核对照片库。换手机请选择新照片库，首版不做跨设备去重。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("隐私") {
                        Text("无账号、无服务器、无统计 SDK。备份文件及记录以明文保存在所选硬盘目录。")
                        Text("请保持 App 在前台。离开 App 时会暂停，返回后点击继续。")
                    }.font(.footnote)
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showingPicker) { DirectoryPicker { model.selectDirectory($0) } }
        .alert("Luna Sync", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading) {
            Text(value.formatted()).font(.title2.monospacedDigit()).bold()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct DirectoryPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = context.coordinator
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

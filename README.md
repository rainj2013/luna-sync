# Luna Sync

iPhone 外接硬盘增量备份工具。SwiftUI + PhotoKit，最低 iOS 18，不需要账号或服务端。照片范围选择使用 ZLPhotoBrowser 5.x。

提供原始照片、视频、RAW/JPEG、Live Photo 配套资源备份；每资源写入后读回 SHA-256 校验，保存硬盘记录，支持暂停、重试及重新连接后恢复。可按今天、最近 7 天、最近 30 天、今年或自定义日期范围做增量备份，也可逐张/滑动多选，或选择首尾两张选中整段照片。保存原始格式，不包含裁剪、调色结果和编辑历史。不会删除手机照片或跟随照片库删除硬盘文件。

界面按 Luna-Sync-Design-Handoff 重建为 `概览 / 记录 / 文件` 三个一级模块，设置从概览右上角进入。备份流程为“选择备份目录 → 选择照片范围 → 扫描预览 → 确认备份”，并提供独立的进度、暂停、完成与异常页面。`文件` 是与备份目录无关的通用硬盘浏览器，支持三列网格、列表、图片/视频筛选、搜索、排序和原文件预览。详见 [设计实施说明](docs/design-handoff-implementation.md)。

界面、权限说明与备份诊断均已抽离为固定标识的中英文资源，支持跟随系统语言和集中修改措辞。后续文案优化可直接修改 String Catalog 和引擎的 `.strings`，不需要改页面逻辑。详见 [文案与多语言](docs/copy-and-localization.md)。

## 在 Mac 构建和安装

当前配置使用 Xcode 26、iOS 18 或更新的 iPhone，以及在系统“文件”App 中可访问的外接硬盘。照片选择使用 `Vendor/ZLPhotoBrowser` 中基于 5.0.0 的本地包，补充实时区间选择刷新接口；无需下载远端依赖。

1. 打开 `LunaSync.xcodeproj`，选择 **LunaSync** scheme。
2. 在目标的 **Signing & Capabilities** 中选择自己的 Team，并将 Bundle Identifier 改成自己可用的标识。
3. 连接 iPhone，启用系统要求的开发者模式，选择真机后运行。个人免费签名的有效期及能力限制由 Apple 决定。
4. 在 App 允许照片权限，连接硬盘，选择最终要存放照片的目录。照片直接写入此目录，不会自动建立 LunaSync、originals 或年月子目录；记录与临时进度集中在 `.luna-sync` 隐藏目录。
5. 选择照片范围后扫描确认，再开始备份。首尾选择在第二次点选后立即勾选整段，完成按钮显示真实数量；可以继续取消个别照片或追加其他区间。视频开关与 iCloud 下载策略在设置中。保持 App 在前台；离开 App 会暂停，返回后手动继续。
6. “文件”是与备份目录完全独立的文件浏览器。首次单独选择移动硬盘根目录后，可以逐层浏览文件夹并预览文件；授权会被记住，预览页可左右切换，并用“完成”关闭。

默认只读取本地原片。云端资源会列为需下载，不会被记作成功；在设置中开启“允许从 iCloud 下载原片”后重试。下载由 PhotoKit 与自己的 iCloud 完成，可能产生网络流量。

允许有限照片权限时，备份仅覆盖授权范围，界面会持续提示。扫描请求包含连拍和隐藏资产；系统最终可返回的范围仍由权限和系统行为决定。

无签名构建：

```bash
xcodebuild -project LunaSync.xcodeproj -scheme LunaSync \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 核心测试

在 Linux 或 Mac 安装 Swift 5.9 以上版本，然后运行：

```bash
swift test
```

测试使用模拟照片库及临时目录，覆盖增量识别、Live Photo 半完成、RAW+JPEG、取消、五个提交中断点、同大小内容损坏、文件缺失、目录穿越和符号链接、照片库重新关联、版本兼容与万张资产规划。它们不能替代真实 iPhone、PhotoKit 和外接硬盘验证。

GitHub Actions 使用 Xcode 26.3，执行 Linux/macOS 测试、多语言检查和 iOS 模拟器/真机 Release 无签名构建，支持推送、PR 和手动运行。在成功运行的 **Artifacts** 中下载 `LunaSync-<commit SHA>`，其中包含模拟器 App ZIP 和 `LunaSync-unsigned.ipa`。无签名 IPA 需要自行签名后才能安装到 iPhone；此流程不执行 TestFlight 或 App Store 发布。产物保留 14 天，仅上传到 Actions，不提交到 Git 仓库。

## 数据与恢复

新档案使用格式 v2：照片直接保存为所选目录中的原始文件名，只有同名冲突时添加 ` (2)` 等序号，绝不覆盖已有文件。`.luna-sync/archive.json` 标识档案；隐藏目录中的 `records` 保存资源记录，`transactions` 和 `staging` 保存恢复进度与临时内容。可选择已有其他照片的非空目录。

旧版档案头与记录继续可读，既有文件不会自动移动。选择旧版档案根目录后，新增照片也直接写入这个根目录，原始相对路径的旧收据仍可验证和跳过。旧版曾自动创建的 LunaSync 子目录会在恢复时要求重新确认目的地。v1 档案首次写入平铺照片时升级到 v2，旧版 App 会拒绝写入该新格式。

每个资源分块写入 `.partial`，在 PhotoKit 成功结束后读回校验。预期哈希先持久化到事务，再移为正式文件、提交资产记录；Live Photo 全部原始资源完成才计为一张成功。未完成文件从头重传，不做字节级续传。

每轮快速检查已完成文件的存在性及大小；概览与设置中的完整校验会重新读取所有已记录文件，检查内容。校验不符会撤销该资源的完成记录，下次备份重传，异常文件留在硬盘上供检查。旧版本和遗留文件不会自动清理。

手机 SQLite 为可重建缓存，不是成功依据。卸载 App 会丢失本机运行历史和目录授权，但硬盘资源记录仍保留。重新选择原目录、明确选择原照片库后，App 核对重叠资产标识和原始资源描述；无法核对时选择新来源。跨设备不自动去重，不承诺识别相同内容。损坏的单资产记录会保留并提示，健康资产可继续备份；损坏的档案头或事务会停止写入，避免错误恢复。

备份为明文文件。SHA-256 检测内容差异，不证明原始照片在拍摄时没有损坏；exFAT 意外断电的持久性需要连接后重新检查，应用不承诺底层文件系统的原子事务。

## 项目结构

- `Sources/LunaSyncCore`：模型、流式哈希、规划、档案读写、事务恢复和任务协调。
- `Sources/LunaSyncPhotoKit`：iOS 原始资源读取、目录授权、本机 SQLite。
- `App/ContentView.swift`：概览、扫描确认、任务进度、历史与设置。
- `App/DesignSystem.swift`：设计色、排版组件、按钮与真实照片缩略图。
- `App/PhotoScopeView.swift`、`App/FilesView.swift`：照片范围与独立硬盘浏览。
- `App/Localizable.xcstrings`、`App/InfoPlist.xcstrings`：中英文界面与权限文案。
- `Tests/LunaSyncCoreTests`：可在 Linux 和 Mac 运行的核心测试。
- [设计与存储约定](docs/architecture.md)、[真机验收清单](docs/device-validation.md)。

Linux 可以运行核心测试；Apple SDK 适配层和 iOS App 需要在 Mac 上构建。实际 iPhone 与外接硬盘验证见真机验收清单。

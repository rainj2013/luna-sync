# 开发、构建与安装

[返回项目首页](../README.md)

## 构建与安装

需要 Mac、Xcode 26.3、iOS 18+ 的 iPhone，以及能在系统“文件”App 中访问的外置存储。

1. 打开 `LunaSync.xcodeproj`，选择 **LunaSync** scheme。
2. 在 **Signing & Capabilities** 中选择自己的 Team，将 Bundle Identifier 改成自己可用的标识。
3. 连接 iPhone，按系统提示开启开发者模式，选择真机运行。
4. 允许照片权限，连接硬盘，选择备份目录和照片范围，扫描确认后开始备份。

照片选择依赖已放在 `Vendor/ZLPhotoBrowser`，无需拉取远端依赖。个人签名的有效期和能力限制由 Apple 决定。

无签名模拟器构建：

```bash
xcodebuild -project LunaSync.xcodeproj -scheme LunaSync \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 检查与持续集成

Swift 5.9+ 可运行核心测试；多语言检查在 Mac 开发环境执行：

```bash
swift test
swift scripts/check-localization.swift
```

GitHub Actions 使用 macOS 和 Xcode 26.3，执行核心测试、多语言检查，以及模拟器和真机的 Release 无签名构建。成功运行的 Artifacts 中提供模拟器 App ZIP 和无签名 IPA，保留 14 天；IPA 需要自行签名才能安装。当前没有 App Store 或 TestFlight 公开安装入口。

原 Ad Hoc 工作流仅允许私有仓库运行，在本公开仓库中会跳过。若在私有分发环境使用，需要自己的分发证书、已登记设备的描述文件，以及 `ios-adhoc` 环境中的 `APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_PROVISIONING_PROFILE` 和 `APPLE_SIGNING_IDENTITY`。安装包内嵌设备信息，不要公开上传；签名材料应保存在仓库之外或 Secrets 中。

## 项目结构与维护

- `Sources/LunaSyncCore`：备份规划、流式哈希、档案读写、事务恢复与任务协调。
- `Sources/LunaSyncPhotoKit`：PhotoKit 原始资源读取、目录授权、本机 SQLite 缓存。
- `App/`：SwiftUI 界面、照片范围选择、文件浏览与媒体预览。
- `Tests/LunaSyncCoreTests`：核心测试，可在 Linux 和 Mac 运行。
- `App/AppIcon.icon/`：生产图标的 Icon Composer 源文件；README 的 PNG 仅用于展示。

依赖方向为 App → LunaSyncPhotoKit → LunaSyncCore。备份协调器串行管理单个档案任务，资源分块写入并流式计算哈希，不将整段视频载入内存。文件浏览在后台读取和索引目录，只加载可见项，限制图片解码并发和内存缓存，不写入外置存储缩略图缓存。

中英文界面文案分别维护在 `App/Localizable.xcstrings` 和 `App/InfoPlist.xcstrings`；引擎诊断在 `Sources/LunaSyncCore/Resources/{en,zh-Hans}.lproj/Localizable.strings`。修改时保留资源标识和格式化参数，两种语言同步更新，并运行多语言检查。流程判断使用结构化状态，不依赖显示文案。

## 真机检查

使用测试照片和独立备份目录验证以下行为，记录设备、系统、硬盘、连接线和测试结果：

- **权限与连接**：完整、有限、拒绝照片权限；目录重选、失效书签、拔盘重连、只读盘与空间不足。
- **原始资源**：HEIC/JPEG、RAW+JPEG、Live Photo、大视频、编辑过的照片；iCloud 下载开启、关闭及断网时没有假成功。
- **完整性与恢复**：写入或校验时拔盘、强退和后台暂停；已完成文件不重传，未完成文件从头重传；文件缺失、同大小损坏、损坏记录均能正确处理。
- **增量与重装**：重复备份跳过已完成项；新增照片被发现，手机删图不删除硬盘备份；重装后显式关联原照片库。
- **选择与浏览**：日期草稿取消不提交，首尾选择数量与编号一致；大量文件下搜索、排序、滚动和预览可响应，外置盘不新增缩略图缓存。
- **媒体操作**：图片缩放与翻页、视频播放、信息、分享、保存回相册；删除需确认，取消或失败不误报成功。
- **界面与后台**：小屏、辅助功能字号、中英文、VoiceOver；iOS 26 后台继续处理获准与拒绝两条路径，旧系统暂停后可恢复。

核心测试和模拟器截图不能替代真实 iPhone、PhotoKit 与外置硬盘验证，也不能作为真实硬盘吞吐量的结论。

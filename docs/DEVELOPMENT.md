# 开发、构建与安装

[返回项目首页](../README.md)

## 在 Mac 构建和安装

当前配置使用 Xcode 26、iOS 18 或更新的 iPhone，以及在系统“文件”App 中可访问的外接硬盘。照片选择使用 `Vendor/ZLPhotoBrowser` 中基于 5.0.0 的本地包，补充实时区间选择刷新接口；无需下载远端依赖。

1. 打开 `LunaSync.xcodeproj`，选择 **LunaSync** scheme。
2. 在目标的 **Signing & Capabilities** 中选择自己的 Team，并将 Bundle Identifier 改成自己可用的标识。
3. 连接 iPhone，启用系统要求的开发者模式，选择真机后运行。个人免费签名的有效期及能力限制由 Apple 决定。
4. 在 App 允许照片权限，连接硬盘，选择最终要存放照片的目录。照片直接写入此目录，不会自动建立 LunaSync、originals 或年月子目录；记录与临时进度集中在 `.luna-sync` 隐藏目录。
5. 选择照片范围后扫描确认，再开始备份。首尾选择在第二次点选后立即勾选整段，完成按钮显示真实数量；可以继续取消个别照片或追加其他区间。视频开关与 iCloud 下载策略在设置中。建议保持 App 在前台；iOS 26 可请求后台继续处理，能否继续由系统决定，旧系统或请求被拒绝时会在有限收尾时间后暂停。
6. “文件”是与备份目录完全独立的文件浏览器。首次单独选择移动硬盘根目录后，可以逐层浏览文件夹并预览文件；授权会被记住，预览页可左右切换，并用“完成”关闭。

默认只读取本地原片。云端资源会列为需下载，不会被记作成功；在设置中开启“允许从 iCloud 下载原片”后重试。下载由 PhotoKit 与自己的 iCloud 完成，可能产生网络流量。

允许有限照片权限时，备份仅覆盖授权范围，界面会持续提示。扫描请求包含连拍和隐藏资产；系统最终可返回的范围仍由权限和系统行为决定。

无签名构建：

```bash
xcodebuild -project LunaSync.xcodeproj -scheme LunaSync \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 安装包与持续集成

本仓库目前公开源码和无签名构建产物，不提供通用的已签名安装包。原 **Build Ad Hoc IPA** 工作流仅允许私有仓库运行，在当前公开仓库中会跳过；私有分发环境的设备登记、签名和续签方法见 [指定设备安装](ad-hoc-distribution.md)。

GitHub Actions 使用 macOS 和 Xcode 26.3，执行核心测试、多语言检查和 iOS 模拟器/真机 Release 无签名构建，支持推送、PR 和手动运行。在成功运行的 **Artifacts** 中下载 `LunaSync-<commit SHA>`，其中包含模拟器 App ZIP 和 `LunaSync-unsigned.ipa`。无签名 IPA 需要自行签名后才能安装到 iPhone；此流程不执行 TestFlight 或 App Store 发布。产物保留 14 天，仅上传到 Actions，不提交到 Git 仓库。

## 核心测试

在 Linux 或 Mac 安装 Swift 5.9 以上版本，然后运行：

```bash
swift test
```

测试使用模拟照片库及临时目录，覆盖增量识别、Live Photo 半完成、RAW+JPEG、取消、五个提交中断点、同大小内容损坏、文件缺失、目录穿越和符号链接、照片库重新关联、版本兼容与万张资产规划。它们不能替代真实 iPhone、PhotoKit 和外接硬盘验证。

## 项目结构

- `Sources/LunaSyncCore`：模型、流式哈希、规划、档案读写、事务恢复和任务协调。
- `Sources/LunaSyncPhotoKit`：iOS 原始资源读取、目录授权、本机 SQLite。
- `App/ContentView.swift`：概览、扫描确认、任务进度、历史与设置。
- `App/DesignSystem.swift`：设计色、排版组件、按钮与真实照片缩略图。
- `App/PhotoScopeView.swift`、`App/FilesView.swift`：照片范围与独立硬盘浏览。
- `App/Localizable.xcstrings`、`App/InfoPlist.xcstrings`：中英文界面与权限文案。
- `Tests/LunaSyncCoreTests`：可在 Linux 和 Mac 运行的核心测试。
- [设计与存储约定](architecture.md)、[真机验收清单](device-validation.md)。

Linux 可以运行核心测试；Apple SDK 适配层和 iOS App 需要在 Mac 上构建。实际 iPhone 与外接硬盘验证见真机验收清单。

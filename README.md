# Luna Sync

iPhone 外接硬盘增量备份工具。SwiftUI + PhotoKit，最低 iOS 18，无第三方运行时依赖、账号或服务端。

首版提供原始照片、视频、RAW/JPEG、Live Photo 配套资源备份；每资源写入后读回 SHA-256 校验，保存硬盘记录，支持暂停、重试及重新连接后恢复。保存原始格式，不包含裁剪、调色结果和编辑历史。不会删除手机照片或跟随照片库删除硬盘文件。

## 在 Mac 构建和安装

需要 Xcode 16 或更新版本、iOS 18 或更新的 iPhone，以及在系统“文件”App 中可访问的外接硬盘。

1. 打开 `LunaSync.xcodeproj`，选择 **LunaSync** scheme。
2. 在目标的 **Signing & Capabilities** 中选择自己的 Team，并将 Bundle Identifier 改成自己可用的标识。
3. 连接 iPhone，启用系统要求的开发者模式，选择真机后运行。个人免费签名的有效期及能力限制由 Apple 决定。
4. 在 App 允许照片权限，连接硬盘，点击“选择备份目录”，选择硬盘上的父目录。App 在其中创建 `LunaSync`；也可直接选择已有的 `LunaSync` 目录。
5. 点击“开始增量备份 / 继续”，保持 App 在前台。离开 App 会暂停，返回后手动继续。

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

GitHub Actions 已配置 Linux 测试、macOS 测试和 iOS Simulator 无签名构建；仓库推送后才会执行。

## 数据与恢复

硬盘 `archive.json` 标识档案；`records` 是分资产的资源记录；`transactions` 保存中断恢复信息；`originals` 按 UTC 拍摄年月归档，没有日期的资源放在 `undated`。原始文件名保存在 JSON 中，实际路径使用散列及 UUID，避免重名覆盖。

每个资源分块写入 `.partial`，在 PhotoKit 成功结束后读回校验。预期哈希先持久化到事务，再移为正式文件、提交资产记录；Live Photo 全部原始资源完成才计为一张成功。未完成文件从头重传，不做字节级续传。

每轮快速检查已完成文件的存在性及大小；“记录”页的完整校验会重新读取所有已记录文件，检查内容。校验不符会撤销该资源的完成记录，下次备份重传，异常文件留在硬盘上供检查。旧版本和遗留文件不会自动清理。

手机 SQLite 为可重建缓存，不是成功依据。卸载 App 会丢失本机运行历史和目录授权，但硬盘资源记录仍保留。重新选择原目录、明确选择原照片库后，App 核对重叠资产标识和原始资源描述；无法核对时选择新来源。跨设备不自动去重，不承诺识别相同内容。损坏的单资产记录会保留并提示，健康资产可继续备份；损坏的档案头或事务会停止写入，避免错误恢复。

备份为明文文件。SHA-256 检测内容差异，不证明原始照片在拍摄时没有损坏；exFAT 意外断电的持久性需要连接后重新检查，应用不承诺底层文件系统的原子事务。

## 项目结构

- `Sources/LunaSyncCore`：模型、流式哈希、规划、档案读写、事务恢复和任务协调。
- `Sources/LunaSyncPhotoKit`：iOS 原始资源读取、目录授权、本机 SQLite。
- `App`：备份、记录与校验、设置三个页面，以及前后台暂停处理。
- `Tests/LunaSyncCoreTests`：可在 Linux 和 Mac 运行的核心测试。
- [设计与存储约定](docs/architecture.md)、[真机验收清单](docs/device-validation.md)。

当前 Linux 开发环境不能构建 Apple SDK 适配层、签名或验证实际硬盘连接。首次用于唯一照片副本前，按真机验收清单验证实际设备；不要把核心模拟测试结果等同于万张原片真机验收。

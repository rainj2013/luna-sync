# 指定设备安装

使用付费开发者团队的 Apple Distribution 证书和 Ad Hoc 描述文件，给已登记的 iPhone 安装相存，不上传 App Store 或 TestFlight。

## 构建与下载

在私有仓库 Actions 中选择 **Build Ad Hoc IPA → Run workflow**，分支选择 `master`。通过后下载 `LunaSync-AdHoc-<运行序号>-<尝试次数>` 产物，解压获得：

- `LunaSync.ipa`：已签名的 iPhone 安装包。
- `distribution-info.json`：版本、构建号、签名团队、描述文件到期时间及设备数量，不包含设备 UDID。

安装包只保存在私有 Actions 产物中，保留 14 天。IPA 内嵌的描述文件包含可安装设备的标识，因此不要将它公开上传。工作流只允许私有仓库的 `master` 分支运行。

安装包沿用 `dev.lunasync.app`，桌面名称为“相存”，用于更新原应用，不另设家庭版。

## 签名配置

仓库 Environment `ios-adhoc` 仅允许 `master` 分支，保存四项 Secrets：

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE` | 包含证书、私钥和中间证书的加密 P12，以 Base64 编码 |
| `APPLE_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `APPLE_PROVISIONING_PROFILE` | Ad Hoc 描述文件，以 Base64 编码 |
| `APPLE_SIGNING_IDENTITY` | 完整 Apple Distribution 证书名称 |

私钥和描述文件保存在仓库外的本机密钥目录。不要提交 P12、P8、私钥或 `.mobileprovision` 文件。工作流先无签名归档，随后在临时独立钥匙串中导出签名包；只上传通过验证的 IPA 和不含 UDID 的摘要，退出时清理临时凭据。Ad Hoc 不需要 App Store Connect API 密钥。

导出前检查描述文件的有效期、团队、精确应用标识、设备清单、分发权限和证书匹配；导出后检查代码签名、嵌入描述文件、真机平台和签名权限。发现开发描述文件、过期文件或团队/应用不匹配时停止。

## 安装与更新

用 Apple Configurator 在 Mac 上选择已连接的 iPhone，添加解压后的 IPA。也可以使用 Xcode 的 Devices and Simulators 安装。按手机提示信任电脑、开启开发者模式；首次运行可能需要联网验证签名。

后续更新保持相同团队与 `dev.lunasync.app` 标识，通过覆盖安装更新，不要先卸载。首次从个人免费签名切换到其他付费团队时，iOS 可能拒绝直接覆盖；应先保存并验证原应用的本地数据，再处理重新安装和恢复。照片权限和外接目录授权可能需要重新确认。外接硬盘上的备份文件不随应用卸载而删除。

## 添加家人设备

1. 从 Finder 或 Xcode 获取该 iPhone 的 UDID。
2. 在 Apple Developer → Devices 登记设备。
3. 编辑 `Luna Sync Ad Hoc` 描述文件，勾选新设备后重新生成并下载。
4. 通过标准输入更新 `ios-adhoc` 环境的 `APPLE_PROVISIONING_PROFILE`，再运行工作流。

不要在 Issue、提交或 CI 日志中粘贴真实 UDID 或描述文件正文。添加设备会占用开发者团队当年的设备名额。

## 到期处理

以 `distribution-info.json` 中的 `expiresAt` 为准，到期前更新描述文件、必要时更新证书，再生成新安装包。保持付费团队成员资格有效。该方式不是永久签名。

如果只更新描述文件或签名证书，无需修改应用逻辑，但仍需分发签名有效的新安装包。

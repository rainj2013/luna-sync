# 文案与多语言

所有产品界面文案使用固定资源标识。修改措辞时保留标识，只修改对应语言的值，不需要改动 Swift 界面或备份逻辑。

## 文案位置

| 文件 | 内容 |
| --- | --- |
| `App/Localizable.xcstrings` | 页面标题、说明、按钮、范围选择、任务状态、硬盘浏览 |
| `App/InfoPlist.xcstrings` | 系统照片权限弹窗说明 |
| `Sources/LunaSyncCore/Resources/zh-Hans.lproj/Localizable.strings` | 简体中文备份、校验与 PhotoKit 异常说明 |
| `Sources/LunaSyncCore/Resources/en.lproj/Localizable.strings` | 对应英文异常说明 |

现有语言为 `zh-Hans` 和 `en`。App 默认跟随系统/每 App 语言设置；未支持的语言回退到英文。ZLPhotoBrowser 使用其自身的本地化资源。

在 Xcode 打开 String Catalog 后，可以直接搜索现有中文或英文文案；每项的 comment 标注来源文件和英文含义。`copy.*` 标识是固定 ID，不需要根据新文案重新计算，也不要重命名。

## 修改已有文案

1. 在资源文件搜索当前文案，修改相应语言的 `value`。
2. 保留 `%@` 参数的个数。需要调整参数顺序时使用 `%1$@`、`%2$@` 等位置参数。
3. 保留语义必要的换行；中英文可以有不同的自然断行。
4. 执行 `swift scripts/check-localization.swift`，然后构建 App 检查版面。

## 新增语言和文案

- 在 Xcode String Catalog 添加语言，并同时为两个 catalog 补译。
- 为引擎资源新增对应的 `<语言>.lproj/Localizable.strings`，保留全部 `diagnostic.*` 标识。
- 新文案优先使用可读语义标识，例如 `files.search`；通过 `L10n.tr` 或 `L10n.format` 读取。引擎/PhotoKit 使用 `BackupCopy`。
- 文案只负责显示。流程状态使用 `BackupModel.RunState` 等结构化状态，不通过显示文本判断是否完成或失败。
- 文件名、用户目录名、系统返回的错误描述属于运行数据。已有历史中的状态与异常是当时保存的诊断快照，不随语言切换重新翻译。

## 本机视觉检查

Debug 构建支持启动参数 `--review-screen welcome|overview|setup|settings|history|files`，直接打开对应界面，使用真实的空状态和运行数据。该入口不写入演示备份、不构造虚假数量；Release 构建不包含此入口。

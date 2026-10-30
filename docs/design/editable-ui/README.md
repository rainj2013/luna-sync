# Editable design implementation · 2026-10-28

Reference: `/Users/yangyujian/Downloads/Luna-Sync-Editable-Design`. The handoff, interaction specification and tokens are preserved in `reference/`. SVGs/PNGs in that source remain the visual references; native captures belong in `native/`.

## Initial differences and implementation scope

| Existing component | Difference from reference | Change |
| --- | --- | --- |
| `DesignSystem.swift` | Rounded display type, heavy outlines, 56pt/20pt buttons, selected tab backgrounds; largely fixed fonts | Semantic color/layout tokens, 54pt/17pt buttons, 19pt surfaces, scalable SF typography, quiet tabs, accessible headers |
| `OverviewView`, `DestinationCard` | Large hero count, status and total in one panel, heavy card icons | Compact album hero, separate saved/new pair, lighter 77pt destination/range rows |
| `DiskBrowserView` | CTA immediately below a short illustration; little empty-state hierarchy | Folder-specific empty state, larger paper illustration, CTA near bottom without overlapping tabs |
| `DiskDirectoryView` | 24pt folder name, scattered outlined chips, sort row competes with thumbnails | Compact folder/path, segmented filters, one toolbar for existing search/density/sort, wider-feeling grid |
| `ScanPreviewView` | Large count card, repeated headings; no destination summary | Compact review statistics and photo/video breakdown, partial real-photo preview, destination context |
| `TransferView` | Tall image with filename overlay, large completion/pause headings | Smaller preview, fine progress, separate current-file card, calm status emblem and paired metrics |
| `HistoryView`, `SettingsView`, `IntegrityView` | Flat list separators, repeated titles, integrity looked successful before first check | Grouped cards, functional headings, explicit unchecked/checking/issue/success integrity states |
| `PhotoScopeView` | Independently styled methods | Shared colors/radii/scalable fonts; selection behavior unchanged |

Backup, selection, directory permissions, incremental commit/verification and file operations are preserved. The user-stopped background investigation is not resumed.

## Intentional differences from mockups

- No fabricated USB list, byte totals, scan percentage, throughput or ETA. The existing scanner exposes no reliable fractional progress, so scanning remains indeterminate.
- Existing three filters (all/photos/videos) are retained. No unsupported Live Photo file classifier is added to match a static tab.
- No emotional slogans are reintroduced. The user's earlier preference for functional copy still applies.
- Secondary text is slightly stronger than the draft to improve contrast. No new bitmap assets or on-disk thumbnail cache.
- Original quality and per-file verification remain mandatory and are labeled “Always on”; they are not fake optional switches.
- Existing manual backup background capability is retained with its real availability text. The older design specification does not override the later user-authorized implementation.
- New/unfinished/failed states derive from the actual model. Unknown values use a dash. Integrity is neutral until a check completes.

## Visual review fixtures

`--design-fixture` is compiled only for Debug simulator builds. It reads sample JPEG files from a dedicated simulator temporary directory, copies up to six of them into a disposable simulator archive through the existing engine, and derives preview counts from that archive. It does not alter production bookmarks or touch external storage. Active/paused/error states are explicitly staged for layout review, not records of a running backup. System wallpaper JPEGs are used solely as simulator review fixtures; they are not shipped in the app. Debug thumbnail loading for these IDs is also simulator-only, with file loading off the main thread.

Normal captures use `--review-screen <name> --capture-review`. The `native/` captures are native simulator screenshots of the rendered SwiftUI interface, not edited design mockups. Validation results and remaining differences are recorded below after checks complete.

## Per-screen comparison

| Reference | Native capture | Assessment |
| --- | --- | --- |
| [01 disconnected home](reference/screens/01-home-disconnected.svg) | [01](native/01-home-disconnected.png) | Compact status/album hero; destination then scope then fixed action. No duplicate disconnected warnings. |
| [02 ready home](reference/screens/02-home-ready.svg) | [02](native/02-home-ready.png) | Separate saved/new metrics; simulator fixture names/counts reflect its own archive. |
| [03 folder](reference/screens/03-select-folder.svg) | [03](native/03-select-folder.png) | Native authorization and existing named-folder workflow retained; no fake drive enumeration. |
| [04 scanning](reference/screens/04-scanning.svg) | [04](native/04-scanning.png) | Neutral scan state; indeterminate indicator because engine exposes no scan percentage. |
| [05 review](reference/screens/05-review.svg) | [05](native/05-review.png) | Count/skip metrics replace unavailable byte estimate; real partial preview and destination context. |
| [06 transfer](reference/screens/06-backing-up.svg) | [06](native/06-backing-up.png) | Smaller image, fine progress bar and current-file card. No fabricated throughput/ETA. |
| [07 paused](reference/screens/07-paused.svg) | [07](native/07-paused.png) | Retained progress, remaining count and destination. Existing continue/dismiss behavior. |
| [08 complete](reference/screens/08-complete.svg) | [08](native/08-complete.png) | Quiet heart emblem, saved/skipped stats and actual thumbnails. Zero-new uses “Up to date”. |
| [09 history](reference/screens/09-history.svg) | [09](native/09-history.png) | Grouped session cards; existing details/archive-record navigation retained. |
| [10 empty files](reference/screens/10-files-disconnected.svg) | [10](native/10-files-disconnected.png) | Distinguishes no chosen folder from unavailable bookmark; CTA shares the root safe-area inset with tabs. |
| [11 files grid](reference/screens/11-files-grid.svg) | [11](native/11-files-grid.png) | Compact folder name, segmented filters and existing controls. Content leads; no invented Live Photo filter. |
| [12 settings](reference/screens/12-settings.svg) | [12](native/12-settings.png) | Grouped surfaces and native switches; mandatory original/verification settings are explicitly labeled. |
| [13 problems](reference/screens/13-errors.svg) | [13](native/13-errors.png) | Quiet failure state and grouped reason details; existing retry behavior preserved. |
| [14 integrity](reference/screens/14-integrity.svg) | [14](native/14-integrity.png) | Checked/issues stats and actual verification date. Before first check, neutral “Not checked yet” instead of a success claim. |

Extra date review: [equal-width padded date fields](native/15-dates.png).

## Validation

- Debug iOS Simulator and signed iOS device builds succeeded with Xcode 26.3.
- 42 existing engine/index/cache tests passed, including interruption/resume and resource integrity tests. No production backup algorithm or archive layout changed in this UI pass.
- Localization checks: 390 app strings, 1 permission string, 40 engine strings; both en and zh-Hans present. `git diff --check` passed.
- Small secondary text on the hero has computed contrast 4.54:1; white primary-button text is 5.71:1. Disabled controls are intentionally muted.
- Fifteen main-device native captures use a simulator-only sample archive. They are visual state fixtures, not proof of real external-drive performance or background operation.
- iPhone SE (3rd generation, 375×667pt) native layout checks completed for home, empty files and padded date selection: [home](native/SE-01-home-disconnected.png), [files](native/SE-10-files-disconnected.png), [dates](native/SE-15-dates.png). Primary actions remain above the tabs; longer content scrolls.
- Largest accessibility text size was checked on the main simulator (home/settings/dates) and on SE home. The album decoration hides at accessibility sizes and text reflows: [SE accessibility home](native/SE-AX-01-home-disconnected.png). Earlier AX-prefixed captures precede the final fixed icon sizes and scalable tab-label polish.
- Final signed Debug build installed successfully on the paired iPhone 15 Pro on 2026-10-28 at 23:49. The phone was locked, so this pass does not claim a physical-device launch or a real-drive/background acceptance test.

## 2026-10-29 · Settings and integrity follow-up

- Integrity's hollow-circle rows are replaced by one explanatory paragraph headed “校验说明”, so informational scope is not presented as unfinished work. [Native capture](native/refined-14-integrity.png).
- Storage layout is now a collapsed “文件保存方式” disclosure beneath the destination, rather than a navigation action mixed with checks. [Expanded capture](native/refined-settings-storage.png).
- The mandatory post-backup verification setting stays with the backup options. A separate “维护工具” card opens “文件校验”, with a subtitle explaining that results can be viewed or the files checked again.
- Removed the bottom explanatory paragraphs. System settings is a distinct card labeled “系统设置 / 照片权限与应用语言”, with an external-arrow symbol. [Scrolled lower portion](native/refined-settings-system.png), [default settings view](native/refined-12-settings.png).
- Debug simulator/device builds, 398-string localization checks and whitespace checks passed. Installed on the paired iPhone 15 Pro at 00:09. This pass only changes these views and their copy; no new engine tests or background-transfer tests were run.

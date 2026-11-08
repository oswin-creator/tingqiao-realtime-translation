# 听桥 TingQiao 0.2.31

## 更新内容 / What’s new

- 音量动画独立刷新；手动上翻字幕时暂停自动跟随，减少主页面布局冲突。
- 主窗口和字幕悬浮窗拖动边缘时保持内容尺寸，松开后统一排版。拖动期间字幕仍继续更新。
- 版本号旁新增「检查更新」：连接本项目 GitHub Releases，下载并校验安装包、版本、应用标识和签名身份。收音、字幕处理与模型下载结束后才能安装。
- 安装保留模型、记录和设置；应用替换保留旧版，启动失败时可回滚。
- 发布包使用固定自签名证书。从旧 ad-hoc 版本首次升级可能需要重新授权系统录音；后续授权保留仍需由 macOS 验证。
- Android 随身字幕仍为 0.3.2，本次未更改手机功能。

The workspace refreshes the audio meter independently, pauses auto-follow while reading older captions, and defers main/floating window reflow until resize release. **Check for updates** verifies GitHub release assets and signing continuity, then installs when capture and active work have finished. Updates preserve external models, transcripts, and settings. Android remains 0.3.2.

## 安装 / Install

Download the Apple silicon macOS 14+ DMG or the Android 8+ APK from this release. The Mac package is self-signed and is **not Apple-notarized**. First launch may require the confirmation described in [installation help](INSTALL.md). Recognition model weights are downloaded separately in the app.

Mac 下载 DMG 后拖入应用程序。安卓下载 APK 安装；同一 Wi-Fi 下也可以直接用手机浏览器扫码看字幕，无需 App。模型权重、API 密钥、会议内容、配对凭据和签名私钥不包含在安装包中。

## 验证 / Validation

- 131 项窗口缩放检查：120 次拖动尺寸变化期间不重排，结束时提交最终尺寸；拖动期间字幕可以继续更新。
- 15 项字幕滚动、音量刷新和更新安装时机检查。
- 28 项更新来源、版本、校验值、安装与回滚检查。
- 50 项识别与翻译链路恢复检查。
- 固定证书跨版本校验、加密备份恢复验证和本机应用启动检查通过。

The previous intermittent UI freeze was observed in SwiftUI layout. The updated scrolling, meter, and resizing behavior passes these checks; long-session stability continues to need observation.

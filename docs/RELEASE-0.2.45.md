## 听桥 Mac 0.2.45 · 安卓 0.3.4

- **Mac 存储**：原文和译文按记录增量保存。新收音在内存中处理，退出后无法补跑未识别的音频。现有会议历史自动迁移，原 JSON 保留。
- **Mac 播报**：新增本机耳机播报，可选择 MeloTTS 或 Qwen3-TTS。主界面可独立调音量，当前小句显示黄色底纹。
- **安卓字幕**：按钮和字幕布局更紧凑，右上角可主动检查连接。翻译期间 Wi-Fi 字幕查询间隔从约 900 毫秒缩短至 250 毫秒，蓝牙端只刷新变化的字幕。
- **下载**：Apple 芯片 Mac（macOS 14+）使用 DMG，Android 8+ 使用 APK。播报模型可在应用内按需下载，模型所需 macOS 版本见播报设置。Mac 安装包沿用固定签名，未经过 Apple 公证。

## TingQiao for Mac 0.2.45 · Android 0.3.4

- **Mac storage**: Confirmed text is saved incrementally. New recognition audio stays in memory and cannot be resumed after quitting. Existing transcripts migrate automatically and the original JSON file is retained.
- **Mac speech playback**: Listen through headphones using local MeloTTS or Qwen3-TTS, adjust playback volume independently, and see the current phrase highlighted.
- **Android captions**: More compact controls and spacing, an on-demand connection check, faster Wi-Fi polling during translation, and incremental BLE caption rendering.
- **Downloads**: DMG for Apple silicon on macOS 14 or later and APK for Android 8 or later. Speech models are downloaded separately. The Mac package uses the existing signing identity and is not Apple-notarized.

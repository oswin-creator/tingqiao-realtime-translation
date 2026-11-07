# Development / 开发说明

## Source map

| Path | Responsibility |
| --- | --- |
| Sources/AppModel.swift | Capture lifecycle, queues, history, assistant and phone publication |
| Sources/AudioCapture.swift | Microphone and ScreenCaptureKit audio, PCM segmentation |
| Sources/SpeechRecognition.swift, ModernSpeech.swift | Apple speech and explicit resource preparation |
| Sources/WhisperEngine.swift, Tools/Whisper/ | Resident whisper.cpp helper and Metal inference |
| Sources/Translation.swift | Provider requests and translation context |
| Sources/MeetingAssistant.swift | Assistant prompts, reasoning stream, reply limits |
| Sources/Views.swift, FloatingViews.swift | SwiftUI workspace and caption overlay |
| Sources/PhoneServer.swift, Bluetooth*.swift | Wi-Fi and BLE pairing and caption transport |
| Resources/phone.html | Shared phone web view |
| android/app/src/ | Android companion, QR scanner, BLE captions and assistant UI |
| Tests/, android/tests/ | Synthetic tests and device instrumentation |

## Dependencies

- Swift, AppKit, SwiftUI, AVFoundation, ScreenCaptureKit, Speech, CoreBluetooth.
- macOS 26 SDK or newer for compilation, macOS 14+ deployment on arm64.
- whisper.cpp v1.8.2, pinned to 4979e04f5dcaccb36057e059bbaed8a2f5288315.
- Model artifacts and checksums are pinned in Sources/LocalModels.swift. KomixV2 byte vocabulary is generated with Tools/Whisper/generate-vocabulary.py.
- transcribe.cpp for Qwen, pinned to 5700f127e38dd53c4735ea23ef743b4b538eacd4.
- Android Platform 35, Build Tools 36.0.0, minimum API 26, JDK 17.
- ZXing Core 3.5.3, downloaded from Maven Central with a pinned SHA-256.

Third-party license texts live in docs/licenses and application resources. Build output and dependency checkouts stay under ignored directories.

## Recognition timing

The segmenter maintains the current uncommitted audio. A clearly completed sentence may submit after about 0.7 seconds of silence, an unclear ending after about 1.5 seconds. Around 7 seconds it prefers a natural pause, with a 10-second cap. Forced cuts preserve about 1.5 seconds of overlap.

Whisper previews attempt an update every 4 seconds, independent of low-power mode. Busy recognition prioritizes final segments. Confirmed text is checked for repetition before replacing a usable preview. Recognition errors have a bounded automatic retry, with blocked audio retained for manual retry. Phrases of 1–10 characters or words repeated consecutively 10 times are reviewed before publication.

These rules reduce latency and error propagation, with limits in noisy, overlapping, or low-volume speech.

## Validation

The public source was checked with the synthetic Mac and Java test suite and a clean Android build. A synthetic Japanese utterance was transcribed locally with the existing Whisper model before publication. Language-pair request parameters were tested with mock provider responses.

Coverage includes settings migration, language persistence, context ordering, audio segmentation, bounded recognition retries, stable subtitle identity, clear and undo, TXT export, BLE frame reconstruction, QR parsing, assistant limits, and authenticated loopback phone requests.

Hardware tests from development covered selected Mac and Android paths. Multi-hour reliability across all phones, languages, meeting apps, and networks remains to be tested.

## Local configuration

| Variable | Use |
| --- | --- |
| TINGQIAO_BUILD_DIR | Alternate Mac app output directory |
| TINGQIAO_SIGN_IDENTITY | Existing Apple signing identity |
| TINGQIAO_CMAKE | Explicit CMake executable |
| ANDROID_SDK_ROOT | Android SDK location |
| TINGQIAO_DATA_DIR | Isolated transcript directory for tests |

Keep test instances separate from real transcript stores. Do not commit UserDefaults exports, Keychain exports, signing identities, real audio, or paired-device data.

## 文档配图

README 配图 为使用合成内容制作的界面示意。图中对话、状态和回复均为示例，不代表所有界面尺寸或实际识别结果。

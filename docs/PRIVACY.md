# Privacy / 隐私

## Data flow

| Operation | Data processed | Destination |
| --- | --- | --- |
| Whisper / Qwen recognition | Audio segments | Local Mac, via the selected resident helper |
| Apple local recognition | Audio segments | Apple speech APIs on the Mac |
| Apple online recognition | Audio segments | Apple, when local-only recognition is switched off |
| Translation | Confirmed text and optional preceding context | Selected Google, Index, or custom endpoint |
| Meeting assistant | The latest 15 confirmed segments, available translations, and up to five minutes of preceding background | Separately configured assistant endpoint, on request |
| Wi-Fi / BLE captions | Recent captions, status, requested assistant replies | Paired phones |
| Model installation | Model download | Hugging Face for local models, Apple for system resources |

The app stores transcript metadata and pending audio in ~/Library/Application Support/TingQiao/. Segments are saved before recognition. Audio is removed after recognition succeeds and text is saved. Unfinished segments remain for recovery. Clearing history supports undo until permanently deleted.

API keys use the macOS Keychain. The phone protocols do not expose keys or raw meeting audio. App settings use local UserDefaults. Bluetooth credentials are stored on each paired device.

Wi-Fi uses a local HTTP server with pairing credentials and origin checks. Anyone with the full active pairing link may be able to read the shared captions. BLE characteristics require link encryption and an application pairing credential.

The app uses the network for the selected translation and assistant providers, enabled Apple online recognition, model downloads, and enabled phone connectivity. Review your selected provider's terms and retention policy.

## 公开源码检查

公开目录只包含源码、构建脚本、合成测试、图标来源、文档与第三方许可。个人设置、钥匙串、配对数据、真实会议文字和音频、设备调试报告、旧安装包和签名材料未收录。

本机数据路径、固定应用包名和公开服务地址是实现所需的配置标识。示例 API 地址、测试密钥和测试配对凭据仅用于合成测试。

源码中不存在替用户预设的付费 API Key。请在 App 内自行填写，勿把真实密钥写进代码、README、Issue 或截图。

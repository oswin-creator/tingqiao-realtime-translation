# 安装听桥 / Install TingQiao

## Mac

1. 从 [GitHub Releases](https://github.com/oswin-creator/tingqiao-realtime-translation/releases/latest) 下载 macOS arm64 的 DMG，适用于 Apple 芯片 Mac、macOS 14 或更新版本。
2. 打开 DMG，把「听桥.app」拖到「Applications / 应用程序」。
3. 从「应用程序」打开听桥，根据所选收音方式允许系统声音录制、麦克风或语音识别权限。
4. 首次打开可使用简短引导，也可以跳过。需要时在顶部重新打开。
5. 若选择 Whisper，在设置中按需下载约 1.6 GB 的模型。Apple 系统识别按可用的语言资源运行。

当前 Mac 预览包采用 ad-hoc 签名，尚未经过 Apple Developer ID 公证。若系统提示无法验证开发者，请先确认文件来自本仓库。确认信任该文件后，可在尝试打开一次后，到「系统设置 → 隐私与安全性」按 Apple 提供的「仍要打开」流程确认。详见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 安卓随身字幕

1. 下载 Releases 中的 APK，在手机上打开安装，按系统要求允许该下载来源安装应用。
2. 同一 Wi-Fi 下，在 App 扫描 Mac 的二维码或粘贴配对链接。
3. 使用蓝牙时，开启 Mac 蓝牙字幕，在 App 选择电脑，首次输入六位配对码并允许附近设备权限。
4. 手机 App 是字幕伴侣，仍需 Mac 运行听桥来识别和翻译。

同一 Wi-Fi 下，也可以直接使用手机相机扫码，在浏览器打开字幕页面，无需安装 App。

## English

Download the DMG for an Apple silicon Mac running macOS 14 or later. Open it and drag TingQiao into Applications. The current preview is ad-hoc signed and has not been notarized by Apple. Follow [Apple's instructions](https://support.apple.com/en-us/102445) only if you trust the download. Audio permissions are requested for the capture mode you use.

Download and install the APK for Android 8 or later. Connect it to the Mac over Wi-Fi or BLE. For Wi-Fi captions, a phone browser can also open the Mac's QR pairing link without the app. Keep both devices on the same Wi-Fi.

## 校验下载 / Verify downloads

Release 附带 SHA256SUMS.txt。可在下载目录运行以下命令计算哈希，与对应文件名的值比较。

~~~sh
shasum -a 256 TingQiao-macOS-arm64-0.2.22.dmg
shasum -a 256 TingQiao-Captions-Android-0.3.2.apk
~~~

安装包包含程序及第三方许可。Whisper 识别模型权重、个人 API 密钥、会议记录、设备配对凭据和签名私钥不包含在安装包里。

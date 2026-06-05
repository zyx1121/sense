# SpeechAnalyzer / SpeechTranscriber 簡易 Survey

> Apple 在 WWDC 2025 推出的新一代 on-device 語音轉文字 framework。
> 整理日期：2026-06-05 · 適用：iOS 26 / iPadOS 26 / macOS 26 (Tahoe) / visionOS 26+

---

## TL;DR

- `SpeechAnalyzer` 是新的語音分析 **協調器**，本身不做辨識，而是掛載 **module** 來做事。
- `SpeechTranscriber` 是主力的 speech-to-text module；另有 `DictationTranscriber`(聽寫導向)、`SpeechDetector`(VAD)。
- **純 on-device**、模型 asset 由系統按語言下載管理、Swift-first（`async` / `AsyncSequence`）。
- 實測速度比 Whisper Large V3 Turbo 級模型 **快約 2.2×**，品質無明顯差異。
- **這就是 macOS 26 / iOS 26 系統 dictation 背後的新引擎**，現在開放給 app。
- 要支援舊系統 → 退回 `SFSpeechRecognizer`（iOS 10+/macOS 10.15+，但有 rate limit、預設走雲端）。

---

## 1. 背景：兩個世代

Apple 的語音辨識都在 `Speech.framework` 底下，但分成兩代：

| | 舊：`SFSpeechRecognizer` | 新：`SpeechAnalyzer` + modules |
|---|---|---|
| 推出 | iOS 10 / macOS 10.15 | iOS 26 / macOS 26 (WWDC 2025) |
| 預設運算位置 | **雲端**（Apple server） | **純 on-device** |
| On-device | 需 `requiresOnDeviceRecognition=true`，準度較低 | 原生唯一路徑 |
| API 風格 | callback / delegate + request 物件 | `async` / `AsyncSequence`，結構化並行 |
| 長音訊 / 串流 | 受限（單 request ≤ 1 分鐘） | 為長音訊、即時串流設計 |
| Rate limit | 1000 requests/hr/裝置 | 無此限制（本機跑） |

> 重點釐清：系統鍵盤上那顆「麥克風聽寫鍵」的 UI **沒有公開 API 可主動觸發**。
> 你要的是辨識引擎本身 —— 上面這兩套 framework 提供等價甚至更強的能力，由你掌控音訊輸入與結果流。

---

## 2. SpeechAnalyzer 架構

```
            ┌─────────────────────────────┐
  audio ──▶ │       SpeechAnalyzer         │
 (stream)   │  協調器：收音訊、管理 session  │
            │   ┌──────────┬──────────┐    │
            │   │ modules[] (可動態增減)  │    │
            │   └────┬─────┴─────┬────┘    │
            └────────┼───────────┼─────────┘
                     ▼           ▼
            SpeechTranscriber  SpeechDetector ...
                     │
                     ▼  results: AsyncSequence
              volatile / final text
```

- `SpeechAnalyzer` 負責接收音訊、推進分析 session、協調所有掛載的 module。
- module 可在 session 進行中**動態掛載 / 卸載**。
- 結果不是從 analyzer 拿，而是從**各 module 自己的 `results` stream** 拿。

### Module 家族

| Module | 用途 | 備註 |
|---|---|---|
| `SpeechTranscriber` | 一般語音轉文字（主力） | 適合一般對話 / 通用場景 |
| `DictationTranscriber` | 聽寫導向、標點感知、口語化 | 偏近系統 dictation 行為 |
| `SpeechDetector` | 語音活動偵測（VAD），只判斷有沒有人說話 | 只能與 transcriber **搭配**使用，不單獨產文字 |

---

## 3. 核心工作流程

> 以下為依官方 / 社群 sample 整理的**示意骨架**，確切 signature 以 Xcode 內 Speech framework 文件為準。

### 3.1 權限

Info.plist：

```
NSSpeechRecognitionUsageDescription   # 語音辨識用途說明
NSMicrophoneUsageDescription          # 若直接收麥克風
```

runtime 仍需 request authorization。

### 3.2 建立 transcriber + analyzer

```swift
import Speech

let locale = Locale(identifier: "en-US")

// 一行 preset，或自訂 options
let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)

// 自訂版：volatile(逐字即時) + 時間軸標記
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults, .fastResults],   // volatile=邊說邊吐；fastResults=偏即時
    attributeOptions:  [.audioTimeRange]    // 每段附 timestamp
)

let analyzer = SpeechAnalyzer(modules: [transcriber])
```

> ⚠️ **即時性雷**：只設 `.volatileResults` 時 analyzer 偏準確度、**會累積整段語音才一次吐 volatile**（實測：說完才在 0.06 秒內暴吐 41 字，UI 上就是「說完很久才一次全顯示」）。加 `.fastResults` 才邊說邊逐段出。另外把音訊源頭壓到 16k mono（省 48k→16k 重採樣）、開場 `SpeechAnalyzer.prepareToAnalyze(in:)` 預熱 ANE，都能再降延遲。`AnalyzerInput` 的 `bufferStartTime` 是給離線 replay 的，即時串流不需要、也不是延遲主因。

### 3.3 確保模型 asset 已下載

模型按 **語言** 下載，第一次用某 locale 要先確認 asset 在裝置上。

```swift
// 查支援 / 已安裝
let supported = await SpeechTranscriber.supportedLocales
let installed = await SpeechTranscriber.installedLocales

// 缺就下載
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
}
```

### 3.4 餵音訊

兩種模式：

```swift
// (A) 結構化並行：餵一個 audio 的 AsyncSequence
try await analyzer.analyzeSequence(inputSequence)

// (B) 自主模式：直接吃檔案
try await analyzer.start(inputAudioFile: url, finishAfterFile: true)
```

即時串流（麥克風 / 系統音訊）時，把 `AVAudioPCMBuffer` 包成 analyzer 的 input element 後 `yield` 進一個 `AsyncStream` 餵給 `analyzeSequence`。
注意：要先把來源音訊 **resample 成 analyzer 偏好的格式**（可向 transcriber/analyzer 查詢 best available audio format），格式不對會直接失敗。

### 3.5 讀結果

```swift
for try await result in transcriber.results {
    let text = result.text          // AttributedString，含 timestamp 等屬性
    if result.isFinal {
        // 定稿：append 到正式逐字稿
    } else {
        // volatile：暫定結果，用來即時顯示、之後會被覆蓋
    }
}
```

`volatile`(暫定，邊說邊更新) → `final`(定稿) 的雙階段是即時 UI 的關鍵：先秀 volatile 給即時感，定稿時再固定。

---

## 4. 語言支援

- 官方稱支援 **40+ locale**：`en-US`、`de-DE`、`ja-JP`、`zh-CN`、`es-ES`、`fr-FR`、`it-IT` … 等。
- ⚠️ **繁中注意**：來源明確列到的中文是 `zh-CN`（簡體）。`zh-TW` / `zh-Hant` 是否在清單內**請用 `await SpeechTranscriber.supportedLocales` 實測**，不要假設 —— 這對你的中文場景是決定性的，可能要 fallback 到 `SFSpeechRecognizer(locale: zh-TW)` 或外部模型。

---

## 5. 效能與可用性

- **速度**：on-device 處理約為 MacWhisper Large V3 Turbo 的 **2.2×**，品質無明顯差異（MacStories / MacRumors 實測）。
- **平台**：iPhone、iPad、Mac、Vision Pro 全線，需 OS 26 世代。
- **隱私**：純本機，音訊不出裝置。

---

## 6. vs `SFSpeechRecognizer`（要支援舊系統時）

- 吃即時 buffer (`SFSpeechAudioBufferRecognitionRequest`) 或檔案 (`SFSpeechURLRecognitionRequest`)。
- 預設音訊**送雲端**；`requiresOnDeviceRecognition = true` 才純本機（macOS 10.15+，且只有 `supportsOnDeviceRecognition` 為真才行）。
- **硬限制**：每裝置 1000 requests/hr、單一 request ≤ 1 分鐘音訊 → 不適合長時間串流。
- 繁中 locale 支援較成熟（`zh-TW` 可用）。

---

## 7. 採用建議

- **target 得起 OS 26** → 直接上 `SpeechAnalyzer` + `SpeechTranscriber`，尤其長音訊 / 即時串流 / 隱私敏感場景。
- **要支援舊系統 / 需要確定的繁中** → 用 `SFSpeechRecognizer`，注意 rate limit 與雲端隱私。
- **先驗證**：跑一次 `supportedLocales` 確認目標語言；接串流前先確認 audio format 對齊。

---

## 來源

- [SpeechAnalyzer — Apple Developer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber — Apple Developer](https://developer.apple.com/documentation/speech/speechtranscriber)
- [Bringing advanced speech-to-text capabilities to your app — Apple Developer](https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25 (session 277)](https://developer.apple.com/videos/play/wwdc2025/277/)
- [iOS 26: SpeechAnalyzer Guide — Anton Gubarenko](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
- [Hands-On: How Apple's New Speech APIs Outpace Whisper — MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)
- [Apple's New Transcription APIs Blow Past Whisper in Speed Tests — MacRumors](https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/)
- [SFSpeechRecognizer — Apple Developer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- 參考實作：[FluidInference/swift-scribe](https://github.com/FluidInference/swift-scribe)（iOS 26 / macOS 26 全本機 scribe sample）

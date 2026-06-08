```text
██╗  ██╗██╗██╗      ██████╗
██║ ██╔╝██║██║     ██╔═══██╗
█████╔╝ ██║██║     ██║   ██║
██╔═██╗ ██║██║     ██║   ██║
██║  ██╗██║███████╗╚██████╔╝
╚═╝  ╚═╝╚═╝╚══════╝ ╚═════╝
```

# kilo

> macOS 感官 agent — 聽見你在聽的、看見你指的，即時轉錄、整理、分析、記錄。

`SpeechAnalyzer` · `ScreenCaptureKit` · `codex` · `gpt-5.4-mini` · `shake-to-capture`

[English](README.md) · **繁體中文**

## 它做什麼

開著 kilo 看影片、開會、上課：

- **瀏海字幕** — 系統音訊即時轉錄，volatile 灰字逐字打出、定稿轉白，瀏海下方一行流過
- **中英自動切換** — 兩路 SpeechTranscriber 同時轉錄，比較各路定稿信心（EMA + 遲滯），講到哪個語言就自動走哪路
- **連續逐字稿** — 可拖動的 overlay 視窗累積全文；小模型背景把生稿補標點、修辨識錯字、分段 — 灰字尾巴一直流入，幾秒後被整理過的白字取代
- **問 Kilo** — 輸入框直通 codex agent（帶最近逐字稿 + session 記憶），tool use 步驟即時浮出、回應打字機串流；說「記錄下來」它就寫筆記進 `~/.kilo/`，回覆裡的路徑點了直接開
- **Shake 圈選** — 晃游標進選取模式：螢幕變暗、游標下的 UI 元素亮起，左鍵點擊收集（文字收文字、其他截圖），右鍵結束；素材變輸入框上方的 chips，下一輪丟給 codex 看圖分析
- **環境感知** — 背景觀測你當下在哪個 app、看什麼視窗（YouTube 影片、會議、Finder 資料夾）、哪個 app 在發聲，以及 Desktop/Documents/Downloads 的檔案操作；每輪當成「你正在做什麼」一起給 codex

## Pipeline

```
系統音訊 (ScreenCaptureKit) ─→ SpeechAnalyzer ─→ 瀏海字幕 (volatile/final)
                                  └→ 連續逐字稿 ─→ 小模型整理 (gpt-5.4-mini) ┐
視窗/app · 發聲來源 · 檔案操作 (AX · Core Audio · FSEvents) ─→ ObservationStore  ├─→ codex exec ─→ feed
晃游標 ─→ dim + AX spotlight ─→ 點擊圈選 ─→ chips                              ┘
```

## 跑起來（不開 Xcode）

```bash
make run       # build + bundle + codesign + open
make install   # 裝進 /Applications（開機自啟與穩定 TCC 都需要）
make locales   # dump SpeechTranscriber 支援語言
make logs      # 即時看 Telemetry（asr / polish / agent / shake）
```

裝好後選單列會有 kilo 圖示 — 開逐字稿資料夾、權限設定、開機自啟、重啟、結束都在那。

## 分發（給別人）

```bash
make dmg       # 開發態 app 打成 DMG（對方需「右鍵 → 打開」繞過 Gatekeeper）
make release   # Developer ID 簽 + Apple 公證 + DMG，對方雙擊即裝
make publish   # make release + 傳上 GitHub Release（簽名私鑰不出本機）
```

`release` 一次性前置：Apple Developer Program 簽發 **Developer ID Application** cert、`xcrun notarytool store-credentials kilo-notary …` 存公證憑證、`Makefile.local` 設 `DEV_ID_APP`（見 Makefile `release` 註解）。

需求：

- **macOS 26+**（SpeechAnalyzer）
- **Apple Development cert** — hash 放 `Makefile.local` 的 `SIGN_ID`（gitignored），沒有就 ad-hoc 簽
- **codex CLI** 在 PATH（agent 引擎；`zsh -lc` 載入，fnm shim 也通）
- **OpenAI key** 在 Keychain（`service=kilo account=openai`）— agent 與逐字稿整理的 fallback 用；沒有 key 字幕與逐字稿照常，agent 停用
- 權限：**螢幕錄製**（系統音訊 + 圈選截圖）、**輔助使用**（shake 元素探測、點擊攔截、前景視窗觀測），首次啟動會提示

逐字稿整理走 `gpt-5.4-mini` 直打 API（沒 OpenAI key → 原文直出，不整理）。

```bash
./build/kilo.app/Contents/MacOS/kilo --langs zh-TW,en-US   # 雙路信心擇優（預設）
./build/kilo.app/Contents/MacOS/kilo --lang ja-JP          # 單語模式
```

## 隱私 — 資料去哪

kilo 是感官 agent，會錄系統音訊、截你圈選的畫面，並被動觀測你的前景視窗與檔案操作。資料流向講清楚：

| 資料 | 去哪 |
|---|---|
| 系統音訊 | **本機** SpeechAnalyzer 即時轉錄，音訊不離開你的 Mac |
| 逐字稿 | 送 **OpenAI** `gpt-5.4-mini` 整理潤稿 |
| 你的指令 + 最近逐字稿 + 圈選截圖 | 送 **codex / OpenAI** 產生回應 |
| 前景視窗標題 + 發聲來源 + 檔案操作 | **本機** 觀測，跟逐字稿同一條路送 **codex / OpenAI** 當當下 context |
| 筆記 / 逐字稿存檔 | **本機** `~/.kilo`，不上傳 |

**key 與 codex 都是你自己的** — kilo 用你 Keychain 裡的 OpenAI key、你 PATH 上的 codex CLI，不內建、不代管、不經過作者的任何伺服器。送什麼給 OpenAI 由你的使用決定，kilo 只是把它接起來；逐字稿與筆記只存在你本機的 `~/.kilo`。

## 結構

```
Sources/kilo/
├── App/         main.swift — 接線與啟動
├── Audio/       ScreenCaptureKit 系統音訊 → PCM
├── Transcript/  SpeechAnalyzer 轉錄 + store + 小模型整理
├── Agent/       codex exec --json 串流 + session resume
├── Overlay/     瀏海字幕 + 主視窗（逐字稿 / feed / chips）
├── Core/        Telemetry / Keychain / Metrics / ObservationStore（觀測統一層）
├── Observe/     視窗/app（AXObserver）+ 發聲來源（Core Audio）+ 檔案操作（FSEvents）
└── Shake/       晃游標圈選（ported from zyx1121/shake）
```

## 設計依據

`docs/` — [SpeechAnalyzer survey](docs/speechanalyzer-survey.md)、[瀏海 overlay 自刻筆記](docs/macos-notch-overlay.md)、[CLI 開發流程](docs/macos-cli-dev.md)、[AX 操作可行性](docs/ax-actions-survey.md)、[分發 checklist](docs/distribution-checklist.md)。

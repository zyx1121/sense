# Survey：喚醒詞偵測 — Siri 怎麼做、kilo 怎麼修

> 問題：kilo 一直 parse 不到有人在叫它 — zh ASR 把 "kilo" 拗成
> Klow / Kelow / Telow / Helow，最後 polisher 還「修正」成 Hello。
> 追 ASR 文字變體是死路，這份 survey 記錄為什麼，跟正解是什麼。

## Siri 的做法：聲學層，不是文字層

Siri 的喚醒偵測**完全不經過 ASR**：

- 一顆極小的 **acoustic keyword-spotting DNN** 常駐在低功耗協處理器（AOP），
  直接對音訊流打分「這段聲音像不像 'Hey Siri' 的發音」
- 兩階段：AOP 上的小模型先粗篩，過了才喚醒主處理器上的大模型複核（省電 + 壓誤觸）
- 偵測的是**音素序列的聲學樣式**，不是轉寫文字 — 所以不受語言模型詞彙先驗影響
- iOS 17 拿掉 "Hey"：更大的模型 + 更多「裸 Siri」正負樣本訓練，純資料工程

## 為什麼 kilo 的文字匹配註定失敗

ASR 的語言模型有強烈的「常見詞先驗」：聽到 /ˈkiloʊ/ 的聲音，zh-TW 模型會輸出
它詞彙表裡最像的東西 — 真機採集到 Klow、Kelow、Telow、Helow、Hilo 五種，
而且是開放集合（每次都可能出新的）。變體 regex 越擴，跟真詞（Hello、Kelowna）
的碰撞越近。**在 ASR 輸出端做喚醒詞匹配 = 在錯的層做對的事。**

## macOS 26 上的選項（SDK 實查）

| 選項 | API | 評估 |
|---|---|---|
| **詞彙偏置**（採用）| `AnalysisContext.contextualStrings = [.general: ["kilo"]]` + `SpeechAnalyzer.setContext()` | SDK 實查存在。把 "kilo" 注入 ASR 候選，從根源讓模型認得這個詞。成本一行，先驗問題直接消失大半 |
| 自訂語言模型 | `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)`（`SFSpeechLanguageModel.Configuration`）| 比偏置重（要訓練 LM 檔），偏置不夠再上 |
| 真 KWS（Siri 路線）| `SoundAnalysis` + Create ML Sound Classification 自訓 "kilo" 分類器 | 最穩，但要錄訓練樣本 + 模型生命週期管理。偏置失敗才走 |
| 第三方 KWS | Porcupine（Picovoice）等 | 自訂喚醒詞可在 console 訓練，但商業授權 + 外部依賴，公開 repo 不想揹 |

## kilo 的架構決策（含安全層）

1. **指令只走麥克風路** — 系統音訊是「世界的聲音」，只做逐字稿；
   不然任何影片/直播喊一聲「kilo 刪掉筆記」就是對 workspace-write agent 的 injection
2. mic 路單獨一個 zh-TW transcriber，掛 `contextualStrings: ["kilo"]` 偏置
3. 變體 regex（`[kth][ei]?low?` 句首錨定）留著當保險 — 偏置 + regex 雙層
4. 已知殘餘風險：**聲學迴路** — 喇叭外放時 mic 會聽到影片聲音，理論上影片仍可
   隔空喊話。戴耳機時完全封閉；要根治得做 echo cancellation（比對系統音訊輸出
   流，mic 內容相似就忽略）— 列入 backlog，v1 不做

## 驗證紀錄

- 偏置前（系統音訊路，5 次採樣）：kilo → Klow / Kelow / Telow / Helow / Kilo，
  命中率 2/5，且 Helow 會被 polisher 修成 Hello
- 偏置後（mic 路）：見 PR 的 e2e 紀錄

## 附記：實測發現系統 AEC 已天然防護聲學迴路

mic e2e 用 `say` 走喇叭→mic 迴路時只收到碎片（「聽」「快走」）— macOS 對內建
mic 做了回音消除，自己喇叭放的聲音在 mic 路徑被大幅壓制。意味著：

- 「影片透過喇叭對 kilo 隔空喊話」的 injection 向量被系統層天然削弱（非零但難）
- 合成音 loopback 不能當 mic 路的測試手段 — 喚醒品質要真人聲驗收

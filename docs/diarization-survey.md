# Speaker Diarization Survey (2026) — kilo-sense 觀點

> 給已經砍掉一整條 diarization pipeline 的人看的 survey。
> 整理日期：2026-06-16 · 適用：macOS 26 / Apple Silicon · on-device、即時、連續轉錄
> 背景：2026-06-14 移除 streaming-EEND (LS-EEND/Sortformer) + voiceprint enrollment + LLM AttributionEnricher,原因是 turn boundary 翻講者身分。

---

## 0. 一句話結論

**不要重做 blind streaming diarization;那是每個 2026 SOTA 系統都還會翻身分的 regime。** 保留現有的 mic-vs-system-loopback「我 / 對方」source split(那是 OS 音訊路由、不是 diarization,零錯誤)。真要再切細「對方那邊有誰」,把它降格成 **enrollment-first 的封閉集合驗證問題**(per-segment 「這是不是 Alice?」cosine 比對 + open-set reject),或乾脆 **離線在收完的逐字稿上做 re-segmentation**,而不是在 live stream 上做。換更好的 streaming 模型只會降低翻身分的頻率,不會移除結構性病因。

---

## 1. 為什麼上次失敗 — 文獻層的解釋(不是調參能修的)

上次的失敗不是 config bug,是 **online EEND 的結構性病因**:它必須在拿到全域證據之前,就 chunk-by-chunk 不可逆地把「講者 → 輸出 slot」綁定,而且沒有回頭修正的機制。

- **PIT 訓練的輸出 channel 沒有固定身分。** EEND 用 permutation-invariant loss 訓練,輸出 channel 不帶固定講者身分,所以模型每一段都得重新決定「哪個 channel 是誰」——這正是 turn change 會翻的那個操作 [arXiv:2208.13085]。Sortformer 論文自己也點明:PIT 下「輸出 channel 在不同 utterance 間沒有固定講者身分」就是 label-switching 的機制 [arXiv:2409.06656]。
- **Speaker-Tracing Buffer 只把過去的決定往前傳,不回修。** naive chunked SA-EEND 退化的主因是「跨 chunk 的 speaker permutation inconsistency」:每個 chunk 各自解一個 permutation,相鄰 chunk 不一致 [Xue et al., arXiv:2006.02616]。STB 是第一個補丁——把帶 permutation 資訊的前段 frame 拼進當前 chunk,讓當前決定跟歷史一致。但它**只往前傳一個過去的決定**;若那個決定本來就錯(例如某講者還沒講夠就被定型),錯誤就被鎖死並一路 trace 下去。這就是 owner 看到的「turn boundary 翻身分」。
  - 註:此「一旦定型就不可回修」是從演算法結構 + 該領域 irreversibility 共識推出的合理推論,**STB 論文本身並沒有明寫一個失敗模式章節**;owner 觀察到的「flip at boundary」也是我們的歸因,不是論文用語。
- **Sortformer 換了 loss,但沒換掉「先定型」這件事。** Sortformer 用 Sort Loss(按講者首次到達時間排序的 BCE)+ positional embedding 取代 PIT 的一部分,讓 slot k = 第 k 個到場的講者 [arXiv:2409.06656]。實務上它**用 hybrid loss(α·Sort + (1−α)·PIT)**,Sort-only 只是 ablation;streaming 版另開一篇 [Streaming Sortformer, arXiv:2507.18446],用 Arrival-Order Speaker Cache (AOSC) 增量追蹤到達順序,設計初衷正是「跨 chunk 維持 label 一致、避免 PIT 式翻轉」。
  - **重要修正(對上一版理解的糾偏):** 「Sortformer 因為 positional embedding 把講者鎖進 slot、重排要重算,所以 boundary 一定翻」這個因果故事 **在文獻裡找不到支持,且與 AOSC 的設計動機相反**。owner 在 streaming 部署裡看到 Sortformer 仍翻,是真實觀察,但**不能歸因到離線 Sortformer 論文**,且「positional-embedding lock」這個機制是未經證實的假說。要解釋只能指向 AOSC 在 jitter / 短 right-context 下的 cache update lag。

**結論框架:** 每個有效的修法都是以下三者之一——(a) 根本沒有 slot 可排(source split、target-speaker);(b) 延後定型(look-ahead);(c) 修正定型(離線 re-seg pass)。挑「更好的 streaming 模型」(Sortformer vs LS-EEND)只移動失敗率,不移除病因。

> ⚠️ **被推翻的舊理解,別寫進設計依據:** 「EEND-EDA 的 attractor 本質上 order-dependent 且不穩,EEND-TA 只提速沒解掉不穩」——**REFUTED**。EEND-TA (arXiv:2312.06253) 的明確動機就是**移除** LSTM 的 order dependence:「transformer decoder 同時看所有 framewise embedding,不受其順序影響」,提速只是副產品。而且 EEND-EDA 原作者主張「shuffle 輸入後 EDA 不依賴輸入順序」,並未把它當不可消除的不穩。那句「EDA struggles to produce well-separated attractor representations for more speakers」在三篇來源裡**都查無此句**,屬捏造/誤植。真正記載的多講者弱點是 LSTM「忘記某些講者」與「預測人數變多時 DER 急遽下降」。

---

## 2. 選項全景

| 方法 | 即時可行? | 解 boundary-confusion? | on-device Swift 成本 | 主要風險 |
|---|---|---|---|---|
| **Apple-native (Speech/SpeechAnalyzer/SoundAnalysis)** | — | — | 零(但沒這功能) | macOS 26 全系列**沒有任何** speaker 模組,別等別設計依賴它 [WWDC25 s277; speech.json] |
| **FluidAudio · LS-EEND** | ✅ default online、最多 10 人 | ❌ 相似聲音會 collide、快速輪替會 collapse | 中(CoreML/ANE,但**目前非 repo 依賴**,要新增) | 上次 collapse 的就是這條;訓練資料偏模擬 [GettingStarted.md] |
| **FluidAudio · Sortformer** | ✅ online、固定 4 slot | △ session 內較穩,但 **boundary 仍翻**(owner 實測+kilo 自己 PR#75/76 記載) | 中(CoreML/ANE,需新增依賴) | 廠商文件「extremely stable」指 session 內 / 跨會議 recall,**不是** turn-boundary;別誤讀 |
| **FluidAudio / pyannote 3.1 · community-1(批次)** | ❌ 離線批次為主 | ✅ 全域 clustering → 每人一個穩定 label | 中 | 需完整音訊;非即時 |
| **sherpa-onnx · offline diarization** | ❌ 離線(pyannote-seg-3.0 + embed + cluster) | ✅(全域 clustering) | 低-中(Apache-2.0,first-party Swift,xcframework+bridging) | 跨語言(zh-en code-switch)準度未實測 |
| **sherpa-onnx · SpeakerEmbeddingManager(register/search)** | ✅ 可逐窗跑 live | ✅ 身分=查表,無 permutation | 低 | open-set threshold 要調;只認已 enroll 的人 |
| **Argmax SpeakerKit (pyannote-community-1, CoreML)** | ❌ 離線批次(無 streaming API) | ✅(全域 clustering) | **最低**(MIT,跟 WhisperKit 同 vendor 同 package,co-load 乾淨) | macOS 13+ vs kilo 釘 macOS 26(相容但要留意) |
| **WhisperKit / 純 STgT 庫** | — | — | — | 只做轉錄,無 speaker;不在此題範圍 |
| **Personal VAD(單目標 3-class)** | ✅ streaming gating | N/A(只判「我 / 非我」,無多講者排序) | 低(130K 參數,可當 embedding 上的小 CoreML head) | 只回答「目標講者在不在講」,不切多人 |
| **Online TS-VAD(每講者一個 enroll-conditioned head)** | ✅ | ✅ **by construction**(無 slot 可排、無 attractor 可不穩) | 高(無現成 Swift/CoreML,要自建) | 只對 enrolled 講者有效;enrollment 品質 / drift;兩個 enrolled 講者重疊 |
| **LLM-fusion(post-correct,如 DiarizationLM/SEAL)** | ❌ 皆離線二次 pass | △ 修 label 不修身分發現;靠外部 metadata 才穩 | 中(要本地 LLM) | 上次 AttributionEnricher 失敗的層;**別復活** |

> 註:FluidAudio Sortformer 的 streaming cadence 是「每 480ms 更新、560ms tentative」,**不是 80ms**;80ms 是上游 NVIDIA 模型內部的 NEST 8× downsample step,別搞混 [GettingStarted.md vs arXiv:2507.18446]。LS-EEND 是「每 100ms 更新、900ms tentative」。

---

## 3. 關鍵洞見 — 什麼真的會跟失敗的 stack 不一樣

失敗的 stack 之所以失敗,是它在做 **open-set 線上身分發現與追蹤**——必須在沒有全域證據時就把匿名 channel 指派給身分。下面三條都是改 **問題本身**,不是換模型。

### (1) Enrollment-first:把問題從「發現+追蹤」降成「查表」(最推)

把身分**事先**綁到一組固定的 enrolled profile,線上就沒有身分指派決策可翻。

- TS-VAD 把每個輸出 channel 綁定一個 enrolled 講者 embedding,channel→identity 在 enrollment 時就固定、不需 PIT「講者 A 永遠輸出到 channel A」[Seq2Seq-TSVAD arXiv:2210.16127; TS-VAD+ APSIPA 2025; Microsoft arXiv:2208.13085]。
- 但**最便宜、最貼 kilo 需求的不是 TS-VAD,而是 verification**:每段 → embedding → 對每個 enrolled profile 算 cosine → argmax 過 threshold = 那個人,否則 unknown。這是**無狀態的 per-segment 是非題**,沒有 turn-boundary 追蹤。open-set 協定有 VoxWatch [arXiv:2307.00169] / VoxBlink2 [arXiv:2407.11510] 形式化。現代 extractor 在 VoxCeleb-1 verification 約 0.4–1.0% EER(WeSpeaker ResNet293 ~0.425%)。
  - ⚠️ **caveat(adversarial 修正):** 那 0.4–1.0% 是 2-utterance verification EER,**不是** open-set ID 錯誤率。gallery 變大、segment 變短(~2–5s)會明顯變差。kilo 的 gallery 很小(幾個常見同事),正是 open-set ID 最容易的區間,所以可行;但別把 verification EER 當成對 gallery 的逐段 ID 錯誤率,且要做 calibrated/AS-Norm threshold + 跨段 score smoothing。
- **修正一個會被誤導的前提:** 「FluidAudio 已是 kilo-sense 依賴,在它上面加 ID 即可」——**REFUTED**。`/Users/loki/kilo-sense/Package.swift` **零宣告依賴**,沒有 FluidAudio;PR#87 已把整條 speaker 程式碼移除;repo 內唯一 FluidInference 引用是借自另一個 sample repo `swift-scribe` 的 buffer 轉換片段。所以走 enrollment-first 是**新增**一個 SPM 依賴(FluidAudio 或 sherpa-onnx)+ 下載 CoreML 模型(~100MB),不是「reuse 既有依賴」。(FluidAudio 的 `extractSpeakerEmbedding(from:)` / `Speaker(id,name,currentEmbedding)` / `initializeKnownSpeakers([...])` API 確實存在、256-d L2-normalized、ANE-only;但**沒有**內建 cosine-vs-enrolled call,要自己算。)

### (2) 離線 / look-ahead re-segmentation:用延遲換穩定

- **延後定型:** FluidAudio 的 `DiarizerTimelineUpdate` 把輸出分 finalized + tentative;只消費 finalized 段、容忍 sub-second 延遲,能避免「naive 逐 frame 立刻 commit」的部分 artifact。
  - ⚠️ **但別當成翻身分的解藥(adversarial 修正):** kilo 的 log 顯示 Sortformer **在 boundary 翻的是身分(identity),不是 commit 時機**——而且 kilo 上次**早就**在做 late-binding(消費 tentativeSegments、polish 時才解 label、加 2s settle delay)。late-binding 改善的是 boundary **placement**,不是 identity 穩定度。文件也沒明寫引擎會「背景持續 refine tentative label 再 finalize」,那是推論。
- **真正不同的是 two-stage local-global:** live 先吐 provisional stream,等一個 utterance / turn-group 收完,再跑一次離線 re-segmentation + 全域 clustering(VBx / EEND-VC / DiariZen / pyannote community-1)**回溯修正** label,才標成 final。這拿即時正確性換最終正確性,是用 streaming UX 拿到離線級準度的唯一路。工程量偏大,但這是「什麼會不一樣」的正解。

### (3) 若硬要 open-set live diarization:買 look-ahead,別承諾正確

- 用 NVIDIA Streaming Sortformer(FluidAudio 的 CoreML target),接受它上限 4 人、且快速輪替下仍翻——用 High-Latency 模式(10s,RTF 0.005)而非 Ultra-Low(0.32s,RTF 0.180)。轉錄 app 容忍 10s lag 遠勝 live caption。
  - ⚠️ **caveat:** 「look-ahead 是 boundary 穩定度的旋鈕、越多 look-ahead 越少翻」是**合理推論但非來源明述**;論文只說降延遲時準度「下降但不嚴重」,沒說準度被 look-ahead「主導」。別把它寫成已證實事實。

### 為什麼 Apple-native 這條不用考慮

macOS 26 全 26.x 在你點名的整個表面(Speech / SpeechAnalyzer / SpeechTranscriber / DictationTranscriber / SpeechDetector / SFSpeechRecognizer;AVFoundation;SoundAnalysis)**零** speaker-segmentation / speaker-ID / speaker-count / per-token 講者標註 [speech.json 完整 symbol list 無任何含 "Speaker" 或 "Diarization" 者; WWDC25 s277]。SpeechAnalyzer 的 Result 只有 text / isFinal / audioTimeRange。SFTranscriptionSegment 也只有 substring/timestamp/duration/confidence/alternativeSubstrings/voiceAnalytics——`voiceAnalytics` 是 pitch/jitter/shimmer,**不是身分**。SoundAnalysis 的 ~300+ 類只認「是什麼聲音」(speech/laughter/...),不認「誰」。**沒有任何訊號顯示 Apple 2026 會補上**;每個要 diarization 的 macOS 26 app 都外掛第三方(swift-scribe/ambient-voice/SpeakerKit),這本身就是沒有原生路徑的旁證。Apple 唯一的「誰在講」原語,就是 kilo 已保留的 mic-vs-loopback 音訊源分流。

---

## 4. 給 kilo-sense 的具體建議(分階段)

約束:連續 on-device、mic+system source 已切「我/對方」、owner 已否決 blind streaming diarization。

**Stage 0 — 維持現狀,把它當 ground truth(零工)**
保留 meeting mode 的 mic-vs-system-loopback 切分。這是單一最有價值、零 diarization 錯誤的一刀,結構上優於任何 diarization 模型。**任何後續 diarization 只能 sub-label「對方」那一路,絕不能蓋過「我 = mic」這個信任源**——blast radius 被框死,就算 sub-label 翻了也不會把「我」標錯。

**Stage 1 — 若要進一步切「對方那邊有誰」,且是已知小集合:走 verification,不走 clustering**
新增 sherpa-onnx(Apache-2.0,first-party Swift,最輕)或 FluidAudio 依賴 → 把每個 buffered turn(turn 邊界由 source split 免費給)抽一個 embedding(WeSpeaker/3D-Speaker)→ 對 enrolled 集合 cosine argmax + threshold,低於門檻 = unknown。無 clustering、無 streaming、無 permutation。這 reuse 上次 voiceprint enrollment 的投資,但丟掉害你翻身分的 online tracking/clustering 層。先做一個小 A/B(verification-label vs 舊 diarization-label,同一批錄音)就能廉價驗證。

**Stage 2(可選)— 若要對「未知講者」做 who-spoke-when:離線批次,不要 live**
用 Argmax SpeakerKit(MIT,跟可能的 WhisperKit/Speech pipeline 同 vendor、Swift/CoreML 整合最乾淨)的離線 pyannote-community-1,**在每個收完的 turn/segment buffer 上**跑批次 diarization,不要跑 live stream。封閉 buffer 上的全域 clustering 給每人一個穩定 label。

**明確不要做:**
- 不要復活任何 Sortformer/EEND **streaming** 路徑(speech-swift CoreML Sortformer、FluidAudio streaming)或 diart 式 online pipeline——那就是失敗 regime。
- 不要復活 **LLM AttributionEnricher**。它在補一個本該由 timeline-finalization / source-anchor 解的問題。文獻證實:每個 LLM diarization corrector 都是離線二次 pass(不適合連續低延遲),而從對話內**名字**反推身分是已知難的 vocative/addressing 歧義——連 DiarizationLM 都靠餵外部 metadata(video title / 與會者名單)而非信任對話內名字 [arXiv:2401.03506 App. B.1 vs B.2]。「稱呼語鏡像陷阱」(說出口的名字指的是對方)是可預期的,因為它在打一個 under-cued 的問題。
  - 若哪天真的要 post-correct,只能用 SEAL 式:把 LLM 條件在離散化的聲學信心上、硬約束 decoding 為 relabel-only,**絕不讓 LLM 自由產文或發明名字**。lexical+acoustic fusion 確實勝過純聲學(AG-LSEC、Contextual Beam Search ~39.8% rel. ΔSA-WER 改善),所以 lexical 信號值得用——但當成對聲學 prior 的受限 nudge,不是身分權威。

**誠實的話:** 對一個個人「我 vs 對方」app,最好的答案很可能就是 **scope 到 enrolled-speaker identification only**(Stage 1),或 **離線在存好的逐字稿上做**(Stage 2)。general N-speaker live diarization 不是 kilo 該扛的問題。

---

## 5. 不確定 / 待驗證 — 本 survey 的邊界

被 adversarial 判為 **refuted** 的(別當依據):
- ❌ 「EEND-TA 只提速、沒解掉 attractor 不穩」——反了,EEND-TA 明確動機是移除 order dependence;「EDA struggles to produce well-separated attractors」一句是捏造。
- ❌ 「Sortformer 因 positional-embedding 把講者鎖 slot,所以 boundary 必翻」——文獻無此因果,且與 AOSC 設計動機相反;是未證實假說。
- ❌ 「2026 on-device 全領域已收斂到離線批次 clustering、且這是避免翻身分的唯一結構解」——反例:Streaming Sortformer(AOSC)、LS-EEND(online attractor)是 2025-26 的 streaming model upgrade,不靠全域 clustering 就維持 label 穩定。離線批次只是其中一條穩定路,不是唯一。
- ❌ 「FluidAudio 已是 kilo-sense 依賴」——Package.swift 零依賴,PR#87 已移除全部 speaker 程式碼;走任何第三方都是新增依賴。
- ❌ 「FluidAudio 文件框的就是 kilo 砍 pipeline 的同一個問題、且打臉 kilo 的判斷」——不是同一個失敗模式:文件「extremely stable」指 session 內 / 跨會議 recall,kilo 砍的是 turn-boundary identity flip;kilo 早已切到 Sortformer(PR#74)正是照文件建議做,沒誤用。

被判 **partially-supported / 須留意** 的(可用但注意邊界):
- △ Sortformer streaming cadence 是 480ms/560ms 不是 80ms;DER 數字隨 latency config 劇烈變動(同模型 13.24%↔42.56% 看人數、Benchmark 高延遲 config 另報 31.7%),**任何單一 DER 都是 config-dependent,非固定屬性**;且 streaming DER 一律比常被引用的離線 DER 差。
- △ late-binding(只消費 finalized)改善的是 boundary placement,**不是** identity 穩定度——別當翻身分的解藥。
- △ 「look-ahead = 翻身分旋鈕」「Streaming Sortformer = 當前 SOTA online」皆為推論,非來源明述(論文只說降延遲準度「下降但不嚴重」)。
- △ verification 的 0.4–1.0% 是 2-utterance EER,非 open-set ID 錯誤率;gallery 大 / segment 短會變差。
- △ DiarizationLM 的亮眼數字僅在 **2-speaker 電話語音(Fisher/Callhome)** 且 **依賴 finetune**(zero-shot 會刪大段文字);AG-LSEC 那組「Fisher 2.37/1.93/1.58」其實是 RT03-CTS 的欄位,Fisher Test 正確值為 2.56/2.03/1.56。
- △ 「稱呼語鏡像陷阱」是 owner 用語,非文獻既有術語;對應到 DiarizationLM metadata-anchoring 是推論(中信心)。

**未驗證 / 範圍外:**
- 沒有任何 2026 系統聲稱**解決** open-set N-speaker streaming 的 boundary 翻身分;共識仍是 look-ahead / two-stage 全域 clustering / 限縮問題來 mitigate。若目標是真 open-set live,誠實答案是 SOTA 沒關上這個 gap。
- 所有 DER/EER 數字皆來自 2-/few-speaker 電話或會議 benchmark,**沒有**針對 kilo 的 zh-en code-switch、連續雙源、Apple Silicon 實測;cross-lingual speaker-ID 準度未測,threshold 上線前必須在 Loki 實際音訊上 pilot。
- FluidAudio CoreML 轉換相對上游 NVIDIA checkpoint 的保真度未複驗;假設 v2/v2.1 行為 = 上游 NeMo 行為。
- Picovoice Falcon 的 9.0% vs 10.3% DER 是廠商自報、且 macOS/Apple Silicon 支援未在所查頁面明述;封閉源 + 強制 AccessKey(線上啟用驗證)+ 批次非 streaming——只在 sherpa-onnx 準度不足時才值得碰。

---

## 6. 實機後記（2026-06-17）— async diart streaming 也驗證過，確認天花板

把第 3/4 節「架構正確」那條真的做出來、實機驗過了。結論：**架構對了仍卡在 embedding 對相似人聲的天花板，threshold 救不了。**

- **做法**（PR #102，已 revert）：獨立 `SpeakerDiarizer` 軌，每 ~10s 餵一 chunk 給 FluidAudio `DiarizerManager.performCompleteDiarization(atTime:)`（pyannote 3.1 CoreML，自己 frame-level 切段 + 跨 chunk 全域 speakerId），講者標非同步以時間戳疊回逐字稿。**這修掉了 #100 的粒度錯**（diarizer 自己切，不靠 ASR chunk）。
- **TTS 自測**（跨性別英文）：切換點 ±0.1s、全域 ID 穩定，漂亮。
- **真實中文雙人對話實機**：`flush` 每 10s 正常、`rms` 正常（音訊有進）、pyannote 每 flush 切 1–3 段 —— 但分群崩：
  - `clusteringThreshold 0.7`（預設）→ 兩個持續對話的人**全併成一個講者**（~95% spk=1）。
  - `0.5`（更嚴）→ 分出兩人，但切成 **30–65 秒的單一講者大塊**，跟不上真實細緻換手（且偶發 spurious 第三人）。
  - 兩端都錯、中間值只是兩種錯混合 → **threshold 這根桿到頭。**
- **根因**：相似同語言（中文、可能同性別）人聲的 pyannote embedding 區分度不足，抓不準換手點 —— 跟第 1/5 節預測一致。**非架構、非門檻、非 bug，是模型對相似人聲的可分性極限。**

**裁決**：live 逐段分人三度撞牆（#100 粒度 → 0.7 併人 → 0.5 大塊），收掉。要分人只剩「離線批次（`OfflineDiarizerManager` + VBx，事後對整段錄音）」、「enrollment-first 認已知的人」或不做 —— 都不是 live overlay。

---

### 主要來源

- Apple: WWDC25 session 277; `developer.apple.com/tutorials/data/documentation/speech.json`(完整 symbol list)
- FluidAudio: `github.com/FluidInference/FluidAudio` README + `Documentation/Diarization/GettingStarted.md` + `API.md`
- Streaming Sortformer: arXiv:2507.18446;HF `nvidia/diar_streaming_sortformer_4spk-v2`/`v2.1`
- Sortformer (offline): arXiv:2409.06656 (ICML 2025)
- EEND / 結構性病因: arXiv:2006.02616 (Speaker-Tracing Buffer); arXiv:2208.13085 (TS-VAD+EEND); arXiv:2106.10654 / 2005.09921 (EDA); arXiv:2312.06253 (EEND-TA)
- Target-speaker / enrollment: Seq2Seq-TSVAD arXiv:2210.16127; TS-VAD+ APSIPA 2025; Personal VAD arXiv:1908.04284 + 2.0 arXiv:2204.03793; VoxWatch arXiv:2307.00169; VoxBlink2 arXiv:2407.11510; WeSpeaker arXiv:2210.17016
- LLM-fusion: DiarizationLM arXiv:2401.03506 (Interspeech 2024) + `github.com/google/speaker-id`; AG-LSEC arXiv:2406.17266; Contextual Beam Search arXiv:2309.05248
- On-device libs: Argmax SpeakerKit `github.com/argmaxinc/argmax-oss-swift`; sherpa-onnx `k2-fsa.github.io/sherpa/onnx`; Picovoice `picovoice.ai/blog/state-of-speaker-diarization`

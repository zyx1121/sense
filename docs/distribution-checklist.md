# Survey：一個 macOS app 分發前的合規 / 要求

> 對 kilo 這種**直接分發**（非 App Store）的 app，哪些是必須、哪些不適用。
> 結論先講：**kilo 上不了 App Store**，所以「隱私權政策 URL / nutrition label / App Review / sandbox」那一整套**不適用**；但「資料揭露 / 授權條款」這些**道德與信任層面**的，給別人用前該補。

## 為什麼 kilo 不上架（決定了哪些要求適用）

Accessibility + CGEventTap + ScreenCaptureKit 系統音訊 + 呼叫外部 `codex` CLI —— 每一條都是 App Store sandbox 禁止的。kilo 只能走 **Developer ID + 公證直接分發**。因此 App Store 的合規流程整套跳過，剩下的是 Gatekeeper 信任鏈 + 自律性的揭露。

## 已達成 ✓

| 項目 | 狀態 |
|---|---|
| Developer ID 簽名 | ✓ |
| 公證 notarize + staple（app + dmg） | ✓ |
| Hardened Runtime（`--options runtime`） | ✓ |
| App icon（.icns，多尺寸） | ✓ |
| `NSScreenCaptureUsageDescription`（螢幕錄製用途說明） | ✓ |
| `LSMinimumSystemVersion` / 版本號 | ✓ |
| `LSUIElement`（menubar-only） | ✓ |
| 拖放式 DMG | ✓ |

## 該補（kilo 現實下真正重要的）

1. **資料揭露（最重要）** — kilo 是感官 agent，錄系統音訊 + 截圖 + 把內容送 OpenAI。給別人用前必須講清楚資料去哪：
   - 系統音訊 → **本機** SpeechAnalyzer 轉錄（不出機）
   - 逐字稿 → **OpenAI** `gpt-5.4-mini`（整理潤稿）
   - 指令 + 最近逐字稿 + 圈選截圖 → **codex / OpenAI**（agent 回應）
   - 筆記 / 逐字稿存檔 → **本機** `~/.kilo`
   不是法律要求（不上架），但敏感資料 + 給別人用 = 信任前提。放 README 顯眼處（+ 之後可選首啟提示）。
2. **LICENSE** — public repo 沒 license 在法律上等於「保留所有權利」，別人不能合法使用 / 改 / 散佈。加一個（MIT 是個人開源工具標配）。
3. **`NSHumanReadableCopyright`**（Info.plist）— about 視窗顯示版權行。小事。

## 上架才需要、kilo 不適用

- 隱私權政策 URL + App Privacy「nutrition label」
- App Sandbox + 完整 entitlements 申請
- App Review 審核
- StoreKit / receipt validation

## 可選（成熟度，非必須）

- **自動更新**（Sparkle framework）— 現在是手動換 DMG；常駐 app 有自動更新體驗更好
- **entitlements 檢視** — 目前無 entitlements 檔也通過公證且運行正常（SCK 走 TCC 不是 entitlement、network client 預設允許、spawn `codex` 子進程在 hardened runtime 預設策略下 OK）。未來若加需要 entitlement 的能力（如 app sandbox、特定硬體）再補
- **crash 報告** — 個人工具可省

## 一句話總結

kilo 的「合規」= Gatekeeper 信任鏈（已做完：簽名 + 公證 + staple）+ 自律揭露（待補：資料流向 + LICENSE）。上架那套對它不適用。

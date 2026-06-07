# Survey：讓 agent 操作 shake 定位到的 UI 元素

> 問題：shake 模式既然能用 AX 定位任意元素，能不能讓 agent **操作**它們 —
> 例如圈一個按鈕叫 agent 定時點擊？
> 結論：**可以，而且我們已有所需權限**。核心 API 是 `AXUIElementPerformAction`，
> 工程難點不在「能不能按」而在「元素參照會過期」與「自動化失控的安全邊界」。

## 可用的操作原語

| 原語 | API | 適用 |
|---|---|---|
| 按下 | `AXUIElementPerformAction(el, kAXPressAction)` | 按鈕、checkbox、連結 — 等同點擊，**不動游標、不搶焦點、app 在背景也行** |
| 列出元素支援的動作 | `AXUIElementCopyActionNames(el, &names)` | 動態發現：AXPress / AXConfirm / AXIncrement / AXShowMenu… |
| 填值 | `AXUIElementSetAttributeValue(el, kAXValueAttribute, "text")` | text field / slider — 先查 `AXUIElementIsAttributeSettable` |
| 聚焦 | set `kAXFocusedAttribute` | 配合鍵盤事件用 |
| 原始事件 | `CGEventPost`（滑鼠/鍵盤） | AX 不通時的 fallback — 但會跟使用者搶游標/焦點，體驗差一級 |

權限：全部走 **Accessibility**，kilo 為了 shake 已經申請過了，零新增授權。

## AX path vs CGEvent 的關鍵差異

`AXPress` 是對元素的語意操作：app 在背景照按、游標不動、使用者打字不被打斷。
`CGEventPost` 是合成輸入：點擊落在「螢幕上那個位置」，會把視窗帶到前景、跟使用者搶輸入 —
只配當 fallback（某些 app 的 AX 樹殘缺，如部分 Electron / 遊戲）。

Web 內容：Safari/Chrome 透過 `AXWebArea` 暴露 DOM，按鈕/輸入框粒度可用；
Electron app 品質參差，落地時要 per-app 實測（`AXUIElementCopyActionNames` 是現成的探測器）。

## 真正的工程難點：stale reference

`AXUIElement` 是活引用 — app 重啟、視窗關閉、版面重排（web 頁面捲動/重渲染）就失效。
「定時點擊」需要跨時間持有，所以要**指紋 + 重定位**：

1. 圈選時存指紋：app bundle id + role + title/description + frame（相對視窗）
2. 每次執行前驗證引用還活著（隨便讀個 attribute，error 就是死了）
3. 死了就重探測：對指紋 app 的 AX 樹做匹配（role+title 為主、frame 為輔）
4. 重定位失敗 → 停止任務 + feed 通知，**絕不盲按座標**

## kilo 的落地架構

```
shake 圈選 → 釘選元素（指紋）→ 輸入框下規則「每 5 秒點一次直到我喊停」
    → agent 解析成結構化任務 {action: press, interval: 5s, until: user-stop}
    → kilo 原生 scheduler 執行 AXPress（codex 不在每次點擊的迴圈裡）
```

關鍵設計：**codex 只負責把自然語言翻成任務描述，執行是 kilo 原生的**。
codex exec 是一次性 subprocess，沒有 callback 通道，也不該為每次點擊付一次 LLM 往返。

## 安全邊界（先想好再做）

- 自動化執行中 overlay 必須有**可見指示**（badge + 哪個元素 + 頻率）
- **一鍵全停**：shake 或 Esc 立即殺掉所有自動化任務
- 預設**白名單目標 app**，不准對 System Settings / 終端機 / 密碼欄（`kAXSecureTextFieldRole`）出手
- 任務有上限（次數 / 時長），不做無限迴圈預設

## 下一步（如果要做）

1. probe：對 2-3 個目標 app（Safari 頁面按鈕、原生 app、一個 Electron）實測
   `AXUIElementCopyActionNames` + `AXPress` 成功率 — API 形狀確定，per-app 行為未實測
2. MVP：釘選 + 固定間隔 AXPress + 可見 badge + shake 全停（不需要 codex 進迴圈）
3. 之後才是條件觸發（「出現某字樣就點」需要輪詢 AX 樹或 screenshot diff，成本高一級）

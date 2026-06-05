# macOS 瀏海動態島 Overlay — 自己刻

> 結論：自刻，不用框架。本質是一個透明 `NSPanel` overlay 貼在 MacBook 瀏海位置，用 SwiftUI 畫內容。
> 整理日期：2026-06-05 · 適用：macOS 12+（瀏海幾何 API）/ 範例用 macOS 13+ SwiftUI

---

## 前提

- macOS **沒有**「動態島」—— 那是 iPhone 14 Pro+ 的硬體（TrueDepth 相機那塊藥丸區），iOS 專屬（官方 `ActivityKit` + WidgetKit 的 `DynamicIsland`）。
- MacBook 上對應的是**瀏海 (notch)**，Apple 官方沒把它做成互動區（官方只給 `MenuBarExtra` / `NSStatusItem` 選單列那條）。
- 所以「macOS 動態島」=自己在瀏海位置貼一個 borderless `NSPanel` overlay。第三方框架（DynamicNotchKit / boring.notch …）本質全是這一招，差別只在包裝。

## 核心就三件事

1. **算瀏海 frame**
2. **透明 borderless `NSPanel` 貼上去**（高 level、跨 Space）
3. **塞 `NSHostingView`** 放你的 SwiftUI view

state machine、style enum、manager、hover behavior 那些都是框架在抽象的東西，自刻全砍。

---

## 1. 瀏海幾何

`NSScreen` 在 macOS 12 為瀏海加的 API：

- `safeAreaInsets.top` → 瀏海高度
- `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`（`NSRect?`）→ 瀏海左右兩側的未遮蔽區；**回 `nil` 表示該螢幕無瀏海**
- 瀏海寬 = `frame.width − leftArea.width − rightArea.width`

```swift
extension NSScreen {
    var notchFrame: NSRect? {
        guard let l = auxiliaryTopLeftArea?.width,
              let r = auxiliaryTopRightArea?.width else { return nil } // nil = 無瀏海
        let w = frame.width - l - r
        return NSRect(x: frame.midX - w / 2, y: frame.maxY - safeAreaInsets.top,
                      width: w, height: safeAreaInsets.top)
    }

    // 無瀏海螢幕的高度 fallback
    var menubarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}
```

> 算法抄自 DynamicNotchKit（MIT，見參考）。無瀏海時用 `menubarHeight` 當高度、任意寬度（~300）兜一個 frame，照樣顯示在螢幕頂部中央。

---

## 2 + 3. 最小骨架（single-file，可跑）

```swift
import AppKit
import SwiftUI

// 透明 overlay panel — 真的只要設這幾個
final class NotchPanel: NSPanel {
    init(_ rect: NSRect) {
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel], // 無邊框、點擊不搶焦點
                   backing: .buffered, defer: false)
        hasShadow = false
        backgroundColor = .clear
        level = .screenSaver                              // 要夠高才蓋得過選單列
        collectionBehavior = [.canJoinAllSpaces, .stationary]
    }
    override var canBecomeKey: Bool { true }              // 要接點擊/鍵盤才需要；純顯示可刪整行
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel?
    func applicationDidFinishLaunching(_: Notification) {
        guard let screen = NSScreen.main else { return }
        // 內容要往瀏海「下方」展開，不然會被實體瀏海黑塊蓋住
        let w = screen.notchFrame?.width ?? 300
        let h: CGFloat = 120                              // 展開高度
        let rect = NSRect(x: screen.frame.midX - w / 2,
                          y: screen.frame.maxY - h, width: w, height: h)

        let panel = NotchPanel(rect)
        panel.contentView = NSHostingView(rootView: NotchContent())
        panel.orderFrontRegardless()                      // 不啟用 app 也顯示
        self.panel = panel
    }
}

struct NotchContent: View {
    var body: some View {
        Text("hi")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)                           // 黑底跟瀏海連成一體
            .clipShape(.rect(bottomLeadingRadius: 16, bottomTrailingRadius: 16)) // 下緣圓角 = 膠囊感
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)                       // agent app，無 dock 圖示，免 Info.plist
app.run()
```

---

## 會踩的雷

1. **AppKit 原點在左下**：貼頂是 `y = frame.maxY − height`，不是 `0`。
2. **內容必須往瀏海下方延伸**：貼在瀏海那塊本身會被實體黑塊蓋住看不到。panel 高度設成展開高（上例 `h=120`），視覺上才像從瀏海長出來。
3. **`level` 要夠高**：`.screenSaver` 才蓋得過選單列；`.floating` 會被選單列壓掉。
4. **不搶焦點**：`.nonactivatingPanel` + `orderFrontRegardless()` 讓前景 app 不被打斷；要內容可互動才加 `canBecomeKey = true`。
5. **無瀏海 Mac / 外接螢幕**：`notchFrame` 回 `nil`，用 `?? 300`（寬）+ `menubarHeight`（高）兜，別讓它 crash。
6. **多螢幕**：`NSScreen.main` 是「目前 key window 所在螢幕」不一定是內建瀏海螢幕；要鎖內建螢幕得自己挑 `screens` 裡 `notchFrame != nil` 那台。
7. **`NSHostingView` 要撐滿 panel**：borderless panel 的 `contentView` 設成 `NSHostingView` 後，必須 `hosting.frame = NSRect(origin: .zero, size: rect.size)` + `hosting.autoresizingMask = [.width, .height]`，否則 SwiftUI 的 `.frame(maxHeight: .infinity)` / `alignment` 全失效，內容卡在 view 的 intrinsic 位置（實測：字幕黏在選單列高度而非瀏海正下方，盯著截圖調半天才發現是這個）。

---

## 動畫 / 圓角

- **展開 / 收合動畫**（動態島的靈魂）：`panel.animator().setFrame(rect, display: true)`，或把高度交給 SwiftUI 內部 `withAnimation` 控制。不用框架。
- **圓角**：內容容器 `.clipShape(.rect(bottomLeadingRadius:bottomTrailingRadius:))`，已在骨架示範。要更貼真實瀏海曲線（反向圓角接合處）再自己畫 `Path`。

---

## 參考

- **DynamicNotchKit（MIT）** — 瀏海幾何 + panel 配置的權威來源，可直接抄算法：
  - [NSScreen+Extensions.swift](https://github.com/MrKai77/DynamicNotchKit/blob/main/Sources/DynamicNotchKit/Utility/NSScreen%2BExtensions.swift) — `hasNotch` / `notchSize` / `notchFrame` / `menubarHeight` fallback
  - [DynamicNotchPanel.swift](https://github.com/MrKai77/DynamicNotchKit/blob/main/Sources/DynamicNotchKit/Utility/DynamicNotchPanel.swift) — `level=.screenSaver`、`collectionBehavior=[.canJoinAllSpaces,.stationary]`、`canBecomeKey` override
- **Apple NSScreen docs**：[safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets) · [auxiliaryTopLeftArea](https://developer.apple.com/documentation/AppKit/NSScreen/auxiliaryTopLeftArea-uglc)
- 想看完整行為（動畫 / 媒體控制 / file shelf）可讀，但 **GPL-3.0、別抄進閉源**：[boring.notch](https://github.com/TheBoredTeam/boring.notch) · [jackson-storm/DynamicNotch](https://github.com/jackson-storm/DynamicNotch)

import AppKit
import SwiftUI

/// borderless panel 必須 override canBecomeKey，input TextField 才拿得到焦點打字。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 縮放快捷鍵（⌘= / ⌘- / ⌘0）的出口；delta 為 nil = 重設。
    var onZoom: ((CGFloat?) -> Void)?

    /// accessory app 沒有 mainMenu，⌘ 快捷鍵沒有 Edit menu 幫忙路由 —
    /// 自己把標準編輯鍵送回 first responder（TextField / 選取中的文字）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // capsLock 進 deviceIndependentFlagsMask，不剝掉的話大寫鎖定期間全部快捷鍵失效；
        // charactersIgnoringModifiers 唯獨不忽略 Shift（⌘⇧Z 回 "Z"），統一小寫再比。
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if flags == [.command, .shift], key == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        }
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        case "=", "+": onZoom?(0.1); return true
        case "-": onZoom?(-0.1); return true
        case "0": onZoom?(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// 可拖動的 Kilo overlay：連續逐字稿 + 指令輸入 + agent 步驟 feed。floating、拖頂部標題列移動、高度動態。
@MainActor
final class SummaryWindow {
    private let panel: KeyablePanel
    private let store: TranscriptStore

    init(store: TranscriptStore, controller: AgentController) {
        self.store = store
        let hosting = NSHostingController(
            rootView: TranscriptView(store: store, controller: controller))
        hosting.sizingOptions = [.preferredContentSize]

        panel = KeyablePanel(
            contentRect: NSRect(x: 80, y: 360, width: 360, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 背景拖曳會攔掉逐字稿的拖曳選字 — 移動視窗只走頂部標題列（WindowDragGesture）
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
        panel.onZoom = { delta in
            if let delta { store.zoom(delta) } else { store.zoomReset() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        observeVisibility()
    }

    /// overlay 收合（SwiftUI 淡出）時 panel 對滑鼠透明 — 隱形的玻璃不該擋到下面的點擊。
    private func observeVisibility() {
        withObservationTracking {
            panel.ignoresMouseEvents = !store.overlayShown
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeVisibility() }
        }
    }

    /// shake 選取模式時抬到 dim（.screenSaver）之上，結束降回 floating。
    func setElevated(_ on: Bool) {
        panel.level = on
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .floating
    }

    /// 視窗的 CG 座標 frame（給 ClickInterceptor 放行用）。
    var cgFrame: CGRect {
        let f = panel.frame
        let primaryH = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main)?.frame.height ?? 0
        return CGRect(x: f.origin.x, y: primaryH - f.maxY, width: f.width, height: f.height)
    }
}

struct TranscriptView: View {
    @Bindable var store: TranscriptStore
    let controller: AgentController

    /// feed step 與輸入框 icon 共用的 gutter 寬 — 所有 icon 的中心落在同一條垂直線。
    private var iconGutter: CGFloat { sz(16) }

    /// 尺寸 × overlay 縮放係數（⌘= / ⌘- 調，UserDefaults 記住）。
    private func sz(_ v: CGFloat) -> CGFloat { v * store.uiScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 唯一的視窗拖曳把手 — 背景拖曳已關（會吃掉拖曳選字），標題列全寬可拖
            HStack {
                Text("Kilo")
                    .font(.system(size: sz(13), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            // 沒這行，panel 非 key 時（overlay 的常態）第一下 click-drag 會被當
            // activation click 吞掉 — 要點一下再拖第二次才動
            .allowsWindowActivationEvents()

            // 連續逐字稿：白(已整理) → 半白(定稿待整理) → 灰(辨識中，打字機)
            if store.transcriptEmpty {
                Text("聽取中…")
                    .font(.system(size: sz(12))).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16).padding(.bottom, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(transcriptText)
                            .font(.system(size: sz(12)))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contextMenu {
                                Button("複製逐字稿") { copyText(String(transcriptText.characters)) }
                                Divider()
                                Button("清除逐字稿（已存檔的不動）", role: .destructive) {
                                    store.clearTranscript()
                                }
                            }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(height: sz(230))
                    .onChange(of: store.transcriptLength) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .padding(.bottom, 6)
            }

            // Kilo feed：跨 turn 歷史保留，自動跟到最新、可往回捲
            if !store.feed.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(store.feed) { step in
                                stepRow(step)
                                    .contextMenu {
                                        Button("複製") {
                                            copyText(step.kind == .reply
                                                ? String(step.rendered.characters) : step.text)
                                        }
                                        Divider()
                                        Button("清除對話與逐字稿（開新 session）", role: .destructive) {
                                            controller.clearConversation()
                                        }
                                    }
                            }
                            Color.clear.frame(height: 1).id("feedBottom")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: sz(280))  // 內容少照內容高，多了封頂開捲
                    .onChange(of: store.feedLength) { _, _ in
                        proxy.scrollTo("feedBottom", anchor: .bottom)
                    }
                }
                .background(.white.opacity(0.04))
            }

            // shake 圈選素材 chips（送出時消耗）
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.attachments) { asset in
                            attachmentChip(asset)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
                .background(.white.opacity(0.04))
            }

            // 指令輸入 → codex agent；按住右 ⇧ 語音口述；相機 = 截游標所在螢幕變 chip
            HStack(spacing: 8) {
                if store.pttRecording {
                    Image(systemName: "mic.fill")
                        .font(.system(size: sz(12))).foregroundStyle(.red.opacity(0.9))
                        .frame(width: iconGutter)
                } else {
                    KiloMark(size: sz(12))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: iconGutter)  // 跟 feed step 的 icon 對齊同一條垂直線
                }
                TextField(store.pttRecording ? "聽你說…" : "問 Kilo，或叫它記錄…（按住右 ⇧ 說話）",
                          text: $store.inputDraft)
                    .textFieldStyle(.plain).font(.system(size: sz(12))).foregroundStyle(.white)
                    .onSubmit { controller.submit(store.inputDraft); store.inputDraft = "" }
                if store.thinking { ProgressView().controlSize(.small) }
                Button {
                    controller.captureScreen()
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: sz(13))).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("截整個螢幕給 Kilo 看")
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.white.opacity(0.06))
        }
        .frame(width: sz(360))
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(in: .rect(cornerRadius: 16))
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.transcriptEmpty)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.feed.count)
        .environment(\.openURL, OpenURLAction(handler: openFeedLink))
        // 自動收合：shake / 打字 / agent / hover 續命；聲音不續命（那是 notch 的事）
        .opacity(store.overlayShown ? 1 : 0)
        .scaleEffect(store.overlayShown ? 1 : 0.96, anchor: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.overlayShown)
        .onHover { hovering in
            if hovering, store.overlayShown { store.touchOverlay() }
        }
        .onChange(of: store.inputDraft) { _, _ in store.touchOverlay() }
    }

    /// reply 裡的連結：http(s) 交給系統；相對路徑 / file 解析到 ~/.kilo 下用預設 app 開。
    /// 沒這層的話 scheme-less URL 會直接丟給 LaunchServices → -50 開不起來。
    private func openFeedLink(_ url: URL) -> OpenURLAction.Result {
        if let scheme = url.scheme, scheme == "http" || scheme == "https" {
            return .systemAction
        }
        let raw = url.scheme == "file"
            ? url.path
            : (url.absoluteString.removingPercentEncoding ?? url.absoluteString)
        let expanded = NSString(string: raw).expandingTildeInPath
        // 相對路徑依序試 workdir 與 workdir/notes（agent 的筆記慣例放 notes/）
        let candidates = expanded.hasPrefix("/")
            ? [expanded]
            : [kiloWorkdir + "/" + expanded, kiloWorkdir + "/notes/" + expanded]
        if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: hit))
            return .handled
        }
        Telemetry.agent.error("feed link not found: \(raw, privacy: .public)")
        return .discarded  // 找不到就吞掉，不彈 -50 dialog
    }

    /// 三層透明度：已整理 → 定稿待整理 → 辨識中。
    private var transcriptText: AttributedString {
        func styled(_ s: String, _ opacity: Double) -> AttributedString {
            var a = AttributedString(s)
            a.foregroundColor = .white.opacity(opacity)
            return a
        }
        return styled(store.polished, 0.92)
            + styled(store.pendingRaw, 0.55)
            + styled(store.volatileShown, 0.38)
    }

    /// 一律 [固定寬 icon gutter][內容]：四種 step 的文字左緣對齊同一條線，icon 中心也對齊輸入框 sparkle。
    @ViewBuilder
    private func stepRow(_ step: AgentStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            stepIcon(step).frame(width: iconGutter, alignment: .center)
            stepBody(step)
        }
        .padding(.top, step.kind == .user ? 4 : 0)  // 每輪指令前留一點空，視覺分段
    }

    @ViewBuilder
    private func stepIcon(_ step: AgentStep) -> some View {
        switch step.kind {
        case .user:
            KiloMark(size: sz(12)).foregroundStyle(.white.opacity(0.45))
        case .tool:
            if step.running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: step.failed ? "xmark.circle" : "checkmark.circle")
                    .font(.system(size: sz(11)))
                    .foregroundStyle(step.failed ? .red.opacity(0.8) : .white.opacity(0.35))
            }
        case .reply:
            // Kilo 說話的標記（cyan），跟 user 的灰 mark 形成你問它答的對話節奏
            KiloMark(size: sz(12)).foregroundStyle(.cyan.opacity(0.9))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: sz(10))).foregroundStyle(.orange.opacity(0.9))
        }
    }

    @ViewBuilder
    private func stepBody(_ step: AgentStep) -> some View {
        switch step.kind {
        case .user:
            Text(step.text)
                .font(.system(size: sz(12))).foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Text(step.text)
                .font(.system(size: sz(10.5), design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reply:
            Text(prefix(step.rendered, step.shownChars))
                .font(.system(size: sz(12))).foregroundStyle(.cyan.opacity(0.9))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Text(step.text)
                .font(.system(size: sz(11))).foregroundStyle(.orange.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 圈選素材小卡：截圖縮圖 / 文字摘要 + 移除鈕。
    @ViewBuilder
    private func attachmentChip(_ asset: Asset) -> some View {
        HStack(spacing: 5) {
            switch asset.kind {
            case .image(let img):
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipShape(.rect(cornerRadius: 5))
            case .text(let s):
                Image(systemName: "text.quote")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Text(s.replacingOccurrences(of: "\n", with: " ").prefix(14))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Button {
                store.removeAttachment(asset)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 7))
        .help(asset.source)
        .contextMenu {
            Button("翻譯") { controller.quickAction(.translate, on: asset) }
            Button("解釋") { controller.quickAction(.explain, on: asset) }
            if case .image = asset.kind {
                Button("抄錄文字") { controller.quickAction(.transcribe, on: asset) }
            }
            Divider()
            Button("移除") { store.removeAttachment(asset) }
        }
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// AttributedString 前 n 個字元（打字機切片，樣式跟著走）。
    private func prefix(_ a: AttributedString, _ n: Int) -> AttributedString {
        let chars = a.characters
        guard n < chars.count else { return a }
        let end = chars.index(chars.startIndex, offsetBy: n)
        return AttributedString(a[a.startIndex..<end])
    }
}

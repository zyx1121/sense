import Foundation

/// 字幕顯示狀態。顯示與辨識解耦：打字機逐字推進；每段獨立、不累積——
/// 一段定稿後，下一段開始就把舊段噴掉重來（final 不長串堆積）。
@MainActor @Observable
final class CaptionModel {
    /// 當前段顯示文字（逐字推進）。
    private(set) var shown: String = ""
    /// 當前段是否已定稿（true = 白字，false = 灰字）。
    private(set) var isFinal: Bool = false
    /// 是否展開顯示（靜音後收合）。
    private(set) var visible: Bool = false

    private var target: String = ""
    private var pendingClear: Bool = false  // 上段已定稿，下個 volatile 視為新段
    private var typeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    func setVolatile(_ text: String) {
        if pendingClear {              // 新一段 → 噴掉上段
            shown = ""; target = ""; pendingClear = false
        }
        isFinal = false
        target = text
        appear()
        pump()
    }

    func commitFinal(_ text: String) {
        isFinal = true
        target = text
        pendingClear = true            // 定稿後不累積，下段會清掉這段
        appear()
        pump()
    }

    /// 逐字把 shown 推進到 target（35ms/字）。
    private func pump() {
        guard typeTask == nil else { return }
        typeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if shown == target { break }
                if target.hasPrefix(shown) {
                    let end = target.index(target.startIndex, offsetBy: shown.count + 1)
                    shown = String(target[..<end])
                } else {
                    shown = target     // 辨識回頭改字，直接對齊不卡住
                }
                try? await Task.sleep(for: .milliseconds(35))
            }
            self?.typeTask = nil
        }
    }

    /// 有內容就展開；靜音 3 秒收合並清空。
    private func appear() {
        visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            visible = false
            shown = ""; target = ""; isFinal = false; pendingClear = false
        }
    }
}

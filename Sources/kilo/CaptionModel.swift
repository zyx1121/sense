import Foundation

/// 字幕顯示狀態。Transcriber 更新、SwiftUI 觀察。
@MainActor @Observable
final class CaptionModel {
    /// 已定稿（白字）。單行顯示時 view 取尾部。
    private(set) var finalized: String = ""
    /// 進行中、會被覆蓋的暫定段（灰字）。
    private(set) var volatile: String = ""

    func setVolatile(_ text: String) { volatile = text }

    func commitFinal(_ text: String) {
        finalized += text
        volatile = ""
        // 避免無限增長：單行也只看得到尾巴，留尾段即可
        if finalized.count > 200 { finalized = String(finalized.suffix(200)) }
    }
}

import Foundation

/// 中英雙路 ASR 的擇優路由：兩路同時轉錄，誰的信心 EMA 高就走誰。
///
/// - 每路 final 用 run 平均信心更新該路 EMA（α=0.5，新值佔一半 — 反應快但不被單句綁架）
/// - 非作用路要贏過作用路 EMA + margin 才切換（遲滯，防語言左右橫跳）
/// - 顯示與逐字稿只吃作用路的 volatile / final；非作用路只餵分數
/// - 切換瞬間：觸發切換的那筆 final 會路由出去（不丟第一句），代價是切換邊界
///   偶爾跟舊路已送出的字重疊 — polisher 會把它整理掉
/// - 單語模式：只有一路，永遠是作用路，零額外行為
@MainActor
final class LanguageRouter {
    private let captions: CaptionModel
    private let controller: AgentController

    private(set) var active: String
    private var ema: [String: Double] = [:]
    // α=0.7：新 final 佔七成，舊段落的高分快速讓位（實測 α=0.5 殘留太黏切不動）
    private let alpha = 0.7
    // margin=0.05：zh 模型亂拗英文仍有 ~0.6 自信，0.10 門檻實測跨不過
    private let margin = 0.05

    init(initial: String, captions: CaptionModel, controller: AgentController) {
        self.active = initial
        self.captions = captions
        self.controller = controller
    }

    func handle(_ r: ASRResult) {
        if r.isFinal {
            if let c = r.confidence {
                ema[r.locale] = alpha * c + (1 - alpha) * (ema[r.locale] ?? c)
            }
            Telemetry.asr.info("final [\(r.locale, privacy: .public)] conf=\(r.confidence ?? -1, format: .fixed(precision: 2), privacy: .public) ema=\(self.ema[r.locale] ?? -1, format: .fixed(precision: 2), privacy: .public) chars=\(r.text.count, privacy: .public)")
            maybeSwitch()
        }

        guard r.locale == active else { return }
        if r.isFinal {
            captions.commitFinal(r.text)
            controller.appendFinal(r.text)
        } else {
            captions.setVolatile(r.text)
            controller.appendVolatile(r.text)
        }
    }

    /// 全局裁決：任何一筆 final 後，看分數最高的路是否該上位。
    /// 兩個實測教訓：
    /// - active 路還沒有分數前不切（冷啟動時 `?? 0` 會被第一筆垃圾分搶走）
    /// - 不能只檢查「剛出 final 的那路」— active 路自己出低分 final 自貶時，
    ///   要回頭看其他路是否早就領先（單向檢查會卡住該切不切）
    private func maybeSwitch() {
        guard let cur = ema[active],
              let best = ema.max(by: { $0.value < $1.value }),
              best.key != active,
              best.value > cur + margin else { return }
        Telemetry.asr.info("language switch \(self.active, privacy: .public) → \(best.key, privacy: .public) (\(cur, format: .fixed(precision: 2), privacy: .public) vs \(best.value, format: .fixed(precision: 2), privacy: .public))")
        active = best.key
    }
}

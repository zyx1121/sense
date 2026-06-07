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

    // 等待切換期間被丟的 inactive finals — 切換時回補，語言交界的句子才不會蒸發
    private var dropped: [String: [(text: String, conf: Double)]] = [:]
    // 回補門檻 per-locale：buffer 低分的語義是「該路對外語的輸出」，分佈不同 —
    // en 對中文垃圾 0.13–0.26（0.45 足擋，且撈得回 ~0.48 的邊界第一句）；
    // zh 對英文亂拗 0.60–0.63（要 0.7 才擋得住）。都是真機實測值。
    private let backfillConfidence: [String: Double] = ["zh-TW": 0.7, "en-US": 0.45]
    private let backfillDefault = 0.7

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

        guard r.locale == active else {
            if r.isFinal {
                dropped[r.locale, default: []].append((r.text, r.confidence ?? 0))
                if dropped[r.locale]!.count > 12 { dropped[r.locale]!.removeFirst() }
            }
            return
        }
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
        backfill()
    }

    /// EMA 爬升等切換的期間，新 active 路的句子已經被丟掉 — 把 buffer 裡
    /// 信心達標的「尾段連續句」補回逐字稿（趨勢被低分筆打斷就停，垃圾分不會混進來）。
    /// 只補逐字稿不補瀏海 — 字幕是當下的 UI，回放舊句很怪。
    private func backfill() {
        let bar = backfillConfidence[active] ?? backfillDefault
        var run: [String] = []
        for e in (dropped[active] ?? []).reversed() {
            guard e.conf >= bar else { break }
            run.append(e.text)
        }
        dropped[active] = []
        guard !run.isEmpty else { return }
        Telemetry.asr.info("backfill \(run.count, privacy: .public) finals after switch to \(self.active, privacy: .public)")
        for text in run.reversed() { controller.appendFinal(text) }
    }
}

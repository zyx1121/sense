import Foundation
import QuartzCore

/// 兩段式語音喚醒（Siri 模型）：
/// - 「kilo 記一下」一句講完 → 直接成指令
/// - 「kilo」（停頓）「記一下」 → 喚醒詞單獨一筆 final 開 8 秒聆聽窗，下一筆整句當指令
///   （實測使用者自然會停頓，喚醒詞跟指令落在不同 final — 單 final 匹配永遠對不上）
/// 只掛麥克風路 — 指令必須出自使用者的嘴，系統音訊說什麼都不算。
@MainActor
final class VoiceWake {
    enum Event {
        case command(String)   // 完整指令，送 agent
        case armed             // 聽到喚醒詞，聆聽窗開啟
    }

    private var armedUntil: TimeInterval = 0
    private let windowSeconds: TimeInterval = 8

    /// 變體集全部來自真機採集：zh ASR 對 "kilo" 的實際輸出。
    /// 偏置（contextualStrings）生效前這就是現實 — 七樓(qī lóu)、K肉 都是 kilo 的中文音譯。
    private static let inline =
        /^(?:hey[ ,，]*|嘿[ ,，]*)?(?:kilo|k[ei]?low?|kito\w?|telow|helow|hilo|七樓|k肉)(?![a-z])[,，、：:。 ]*(.{2,})$/
        .ignoresCase()
    /// 喚醒詞「單獨成句」的判定 — 整筆 final 只有喚醒詞（可帶 嘿/hey 前綴、可重複、可帶標點）。
    /// 誤觸成本只是開一個 8 秒窗（無害），所以比 inline 寬：含 ki、嘿K、連喊碎片。
    private static let alone =
        /^(?:hey[ ,，]*|嘿[ ,，]*)?(?:(?:kilo|k[ei]?low?|kito\w*|telow|helow|hilo|七樓|k肉|ki\w?)[,，。！？!?.：、 ]*){1,4}$/
        .ignoresCase()

    func process(_ text: String) -> Event? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let now = CACurrentMediaTime()

        // 聆聽窗開著：這筆整句就是指令
        if now < armedUntil {
            armedUntil = 0
            return .command(t)
        }
        // 喚醒詞單獨/連喊一筆（「kilo」「Kitol kito kit」）→ 開窗。
        // 先於 inline 檢查：連喊碎片會被 inline 誤拆成「kilo + 碎片指令」。
        if t.firstMatch(of: Self.alone) != nil {
            armedUntil = now + windowSeconds
            return .armed
        }
        // 一句講完型（「kilo 記一下」）
        if let m = t.firstMatch(of: Self.inline) {
            let cmd = String(m.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd.count >= 2 { return .command(cmd) }
        }
        return nil
    }
}

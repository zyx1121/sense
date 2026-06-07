import Foundation

/// 語音指令解析：「kilo 記一下這段」→ "記一下這段"。
/// 只掛在麥克風路 — 指令必須出自使用者的嘴，系統音訊（影片/直播）說什麼都不算。
enum VoiceCommand {
    /// 觸發詞在句首、後跟至少兩個字才算。
    /// mic transcriber 已用 AnalysisContext.contextualStrings 偏置 "kilo"，
    /// 變體集（Klow/Kelow/Telow/Helow — 真機採集）留著當保險。
    /// `(?![a-z])` 擋 Kelowna 類；"hello" 第二個 l 天然不匹配。
    static func parse(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = t.firstMatch(of:
                /^(?:hey[ ,，]*)?[kth][ei]?low?(?![a-z])[,，、：:。 ]*(.+)$/.ignoresCase()),
              m.output.1.count >= 2 else { return nil }
        return String(m.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

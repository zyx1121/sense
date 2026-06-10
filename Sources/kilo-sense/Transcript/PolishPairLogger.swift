import Foundation

/// 把 polisher 的 (raw → cleaned) 配對存成 jsonl 持續累積，當語料本金，不綁特定用途 —
/// 可挑作 few-shot 範例、評測集，或未來要本地化時的現成標籤
///（蒸餾成 on-device 模型的計畫已收掉：2026-06 實測當代 on-device 候選全不及格）。
/// 純 append、與整理流程解耦；只存「真的有改」的對（raw==cleaned = 無資訊量）。
@MainActor
final class PolishPairLogger {
    private let path: String

    init(root: String = kiloWorkdir) {
        let dir = root + "/training"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = dir + "/polish-pairs.jsonl"
    }

    /// 存原料（raw / cleaned / locale / 前文參考 / 時間），不在這裡鎖死下游格式 —
    /// 要用時再轉（few-shot 例句 / 訓練格式）、篩選、去重最有彈性。
    func log(raw: String, cleaned: String, locale: String, contextTail: String) {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !c.isEmpty, r != c else { return }
        let obj: [String: Any] = [
            "raw": r, "cleaned": c, "locale": locale,
            "context_tail": contextTail.trimmingCharacters(in: .whitespacesAndNewlines),
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        append(json + "\n")
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

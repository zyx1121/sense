import Foundation

/// 把 polisher 的 (raw → cleaned) 配對存成 jsonl，當本地整理模型的蒸餾訓練料。
/// teacher = gpt-5.4-mini，每次成功整理就是一對完美標籤；累積夠了拿去 MLX LoRA 微調，
/// 把雲端整理能力蒸餾成 on-device 小模型（kilo 唯一還靠雲端的就是這步）。
/// 純 append、與整理流程解耦；只存「真的有改」的對（raw==cleaned = teacher 沒出力，無學習價值）。
@MainActor
final class PolishPairLogger {
    private let path: String

    init(root: String = kiloWorkdir) {
        let dir = root + "/training"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = dir + "/polish-pairs.jsonl"
    }

    /// 存原料（raw / cleaned / locale / 前文參考 / 時間），不在這裡鎖死 mlx-lm 格式 —
    /// 訓練前再轉 completions/chat、篩選、去重最有彈性。
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

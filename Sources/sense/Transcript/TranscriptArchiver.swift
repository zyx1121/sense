import Foundation

/// 逐字稿持久化：整理過的批次連續追加到 ~/.sense/transcripts/YYYY-MM-DD.md。
/// sense 的記憶從 session 級變長期 — codex workspace 就在 ~/.sense，舊逐字稿直接可查。
/// 來源（app / 視窗標題）變更時插一行 header，筆記有出處。
@MainActor
final class TranscriptArchiver {
    private let dir: String
    private var lastSource: String?
    private var lastDay: String?

    init(root: String = senseWorkdir) {
        self.dir = root + "/transcripts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func append(_ text: String, source: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        let now = Date()
        let day = Self.dayStamp(now)
        let path = "\(dir)/\(day).md"
        var block = ""

        if day != lastDay {
            lastDay = day
            lastSource = nil  // 換日重標來源
            if !FileManager.default.fileExists(atPath: path) {
                block += "# 逐字稿 \(day)\n"
            }
        }
        if let source, source != lastSource {
            lastSource = source
            block += "\n## [\(Self.timeStamp(now))] \(source)\n\n"
        } else if lastSource == nil, source == nil {
            // 完全拿不到來源時至少給時間錨點（一天一次）
        }
        block += t + "\n\n"

        guard let data = block.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func dayStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func timeStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

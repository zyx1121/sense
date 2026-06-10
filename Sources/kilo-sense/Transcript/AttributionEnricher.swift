import Foundation

/// LLM 講者歸屬：低頻背景 pass，把近期輪替（講者代號 + 內容）餵 gpt-5.4-mini
/// （structured output），推每個代號的角色（主持人/來賓/旁白）與可能人名（從互相稱呼），
/// 寫回 SpeakerTimeline 的顯示名 — 之後的 block 從「講者 A」進化成「小明」「旁白」。
/// DiarizationLM（arXiv:2401.03506）的輕量版：只做 forward-only 命名，不回改已歸檔文字。
/// 防幻覺：人名必須是逐字稿裡實際出現過的字串，且 confidence ≥ 0.7 才採用。
@MainActor
final class AttributionEnricher {
    private let store: TranscriptStore
    private let timeline: SpeakerTimeline
    private let apiKey: String?
    private let model = "gpt-5.4-mini"
    private let interval: TimeInterval = 60   // 兩輪之間最少間隔
    private var lastVersion = 0
    private var lastRun = Date.distantPast
    private var running = false
    private var pollTask: Task<Void, Never>?

    init(store: TranscriptStore, timeline: SpeakerTimeline) {
        self.store = store
        self.timeline = timeline
        self.apiKey = Keychain.openAIKey()
    }

    /// 30s 輪詢：有新輪替 + 距上輪 ≥60s + 近期看得到 ≥2 個講者代號才跑。
    func start() {
        guard apiKey != nil else {
            Telemetry.enrich.info("無 OpenAI key — 講者命名停用，分人維持代號")
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.maybeRun()
            }
        }
    }

    private func maybeRun() async {
        guard !running,
              store.turnsVersion != lastVersion,
              Date().timeIntervalSince(lastRun) >= interval else { return }
        let turns = speakerTurns()
        guard Set(turns.map(\.letter)).count >= 2 else { return }  // 單講者沒歸屬可推
        running = true
        defer { running = false }
        lastVersion = store.turnsVersion
        lastRun = Date()
        do {
            try await enrich(turns)
        } catch {
            Telemetry.enrich.error("enrich failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// recentTurns 裡帶講者代號的輪（app 來源的略過）；代號統一還原成字母。
    private func speakerTurns() -> [(letter: String, text: String)] {
        store.recentTurns.compactMap { turn in
            guard let letter = timeline.canonicalLetter(for: turn.source) else { return nil }
            return (letter, turn.text)
        }
    }

    private struct Attribution: Decodable {
        struct Speaker: Decodable {
            let label: String
            let role: String
            let name: String?
            let evidence: String?
            let confidence: Double
        }
        let speakers: [Speaker]
    }

    private func enrich(_ turns: [(letter: String, text: String)]) async throws {
        let rendered = turns.map { "講者 \($0.letter)：\($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let result: Attribution = try await complete(turns: rendered)

        let corpus = turns.map(\.text).joined()
        for s in result.speakers {  // raw 輸出觀測 — 調 prompt / 驗證規則的依據
            Telemetry.enrich.info("raw \(s.label, privacy: .public) role=\(s.role, privacy: .public) name=\(s.name ?? "∅", privacy: .public) conf=\(s.confidence, format: .fixed(precision: 2), privacy: .public) ev=\(String((s.evidence ?? "∅").prefix(40)), privacy: .public)")
        }
        var roleCount: [String: Int] = [:]
        var accepted: [(letter: String, role: String, name: String?)] = []
        for s in result.speakers where s.confidence >= 0.7 {
            let letter = s.label.replacingOccurrences(of: "講者 ", with: "")
            guard letter.count == 1, letter >= "A", letter <= "Z" else { continue }
            // 人名防幻覺：name 須逐字出現；evidence 須正規化後（去標點/大小寫）出現 —
            // LLM 引句跟 polished 原文常差在標點，逐字比對會誤殺真引句
            let name = s.name.flatMap { n -> String? in
                guard corpus.contains(n),
                      let e = s.evidence, !e.isEmpty,
                      Self.normalized(corpus).contains(Self.normalized(e))
                else { return nil }
                return n
            }
            guard name != nil || s.role != "講者" else { continue }  // 無名 + 通用角色 = 沒資訊
            if name == nil { roleCount[s.role, default: 0] += 1 }
            accepted.append((letter, s.role, name))
        }
        var names: [String: String] = [:]
        for a in accepted {
            // 有名字用名字；同角色多人掛字母（來賓 A / 來賓 B），單人直接角色（旁白）
            names[a.letter] = a.name ?? (roleCount[a.role, default: 0] > 1 ? "\(a.role) \(a.letter)" : a.role)
        }
        timeline.setDisplayNames(names)
        Telemetry.enrich.info("speaker map: \(names.map { "\($0.key)→\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
    }

    /// 去標點、去空白、lowercase — 引句比對用的正規化。
    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// chat completions + json_schema strict — 跟 polisher 同一條 API 通道。
    private func complete(turns: String) async throws -> Attribution {
        guard let apiKey else { throw NSError(domain: "Enrich", code: 0) }
        let instructions = """
            你是逐字稿的講者歸屬分析員。給你一段內容（影片/會議/podcast）的近期逐字稿輪替，\
            講者以代號標示。根據說話內容與彼此稱呼，判斷每個代號的角色與可能的名字。規則：
            - 稱呼語邏輯（最重要，想清楚再答）：講者句中出現的名字幾乎都是「對方」的名字 — \
            呼喚（「Sarah, 請說」）、感謝（「Thank you David」）、介紹來賓，都是在說別人；\
            把那個名字綁給「被稱呼的那一方」，不是說話者自己。\
            只有自我介紹（「我是 X」/ "I am X" / "my name is X"）才能把名字綁到說話者本人
            - 名字必須是逐字稿文字中實際出現過的字串，沒有就 null，絕不編造
            - 每個非 null 的 name 都要給 evidence：逐字稿中支持這個綁定的原句
            - 角色四選一：主持人、來賓、旁白、講者（旁白 = 無對話對象的敘述者；無法判斷用講者）
            - 有清楚依據（自我介紹、被呼喚、被介紹）就給名字，不要過度保守 — 寧可給出名字加上中等 confidence
            - confidence 0 到 1，不確定就低
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "speakers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string"],
                            "role": ["type": "string", "enum": ["主持人", "來賓", "旁白", "講者"]],
                            "name": ["type": ["string", "null"]],
                            "evidence": ["type": ["string", "null"]],
                            "confidence": ["type": "number"],
                        ],
                        "required": ["label", "role", "name", "evidence", "confidence"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["speakers"],
            "additionalProperties": false,
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": turns],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "speaker_attribution", "strict": true, "schema": schema],
            ],
            "max_completion_tokens": 600,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
              let parsed = try? JSONDecoder().decode(Attribution.self, from: Data(content.utf8))
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Enrich", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "attribution API error: \(body.prefix(200))"])
        }
        return parsed
    }
}

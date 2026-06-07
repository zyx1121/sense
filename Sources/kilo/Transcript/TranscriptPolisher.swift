import Foundation
import FoundationModels

// 指令（含前文參考）全放 system / instructions，user message 只放純 raw 文字 —
// 小模型會把混在 user message 裡的 scaffold 標記與「前文參考」當內文照抄（nano 實測翻車）。
private let polishInstructions = """
    你是逐字稿整理員。使用者訊息是一段語音辨識的原始逐字稿，整理它：
    - 補上標點符號，在語意轉換處用換行分段
    - 只修正非常明顯的辨識錯誤（同音字、斷詞）；不確定就保留原字，不要改寫、不要潤飾
    - 保持原語言：中文用中文標點；英文保持原本的大小寫，用英文標點（. , ?），不要用中文句號
    - 不增刪內容、不摘要、不回答問題、不加任何說明或標記
    只輸出整理後的文字本身。
    """

/// 前文參考併進 system 層（銜接語氣與分段用）— 不放 user message，降低被照抄的機率。
private func composeInstructions(contextTail: String) -> String {
    guard !contextTail.isEmpty else { return polishInstructions }
    return polishInstructions
        + "\n\n已整理的前文結尾（僅供銜接參考，它不是輸入、絕對不要輸出它）：\n\(contextTail)"
}

protocol PolishBackend: Sendable {
    var name: String { get }
    func polish(chunk: String, contextTail: String) async throws -> String
}

/// on-device Apple Intelligence — 免費、本地、無網路。每次開新 session 避免 4k context 累積爆掉。
struct FoundationModelBackend: PolishBackend {
    let name = "on-device"

    func polish(chunk: String, contextTail: String) async throws -> String {
        let session = LanguageModelSession(instructions: composeInstructions(contextTail: contextTail))
        let r = try await session.respond(to: chunk)
        return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// OpenAI fallback — Apple Intelligence 沒開時用 nano 級 model 直打 API（不走 codex exec，省 22k token 的 agent prompt）。
struct OpenAIPolishBackend: PolishBackend {
    let apiKey: String
    var model = "gpt-5.4-nano"
    var name: String { model }

    func polish(chunk: String, contextTail: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": composeInstructions(contextTail: contextTail)],
                ["role": "user", "content": chunk],
            ],
            "max_completion_tokens": 2000,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Polish", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "polish API error: \(body.prefix(200))"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 小模型即時整理逐字稿：pendingRaw 滿 60 字立刻整理、不滿則 4s idle 後整理；
/// 一次一個 in-flight，失敗就原文轉正不卡流。backend 不可用 → 整理關閉（raw 留在 pendingRaw）。
@MainActor
final class TranscriptPolisher {
    private let store: TranscriptStore
    private let backend: PolishBackend?
    private var running = false
    private var idleTask: Task<Void, Never>?

    var backendName: String { backend?.name ?? "無（原文直出）" }

    init(store: TranscriptStore) {
        self.store = store
        if SystemLanguageModel.default.isAvailable {
            backend = FoundationModelBackend()
        } else if let key = Keychain.openAIKey() {
            backend = OpenAIPolishBackend(apiKey: key)
        } else {
            backend = nil
        }
    }

    /// 每段 final 進來後呼叫。
    func nudge() {
        guard backend != nil, !running else { return }
        if store.pendingRaw.count >= 60 { kick(); return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            if !store.pendingRaw.isEmpty { kick() }
        }
    }

    private func kick() {
        guard let backend, !running else { return }
        let chunk = store.pendingRaw
        guard !chunk.isEmpty else { return }
        running = true
        idleTask?.cancel()
        let tail = String(store.polished.suffix(120))
        Task {
            do {
                let cleaned = try await backend.polish(chunk: chunk, contextTail: tail)
                store.commitPolished(cleaned.isEmpty ? chunk : cleaned, consumed: chunk.count)
                Telemetry.polish.info("polished \(chunk.count, privacy: .public) -> \(cleaned.count, privacy: .public) chars")
            } catch {
                store.commitPolished(chunk, consumed: chunk.count)  // 原文轉正，不卡顯示
                Telemetry.polish.error("polish failed: \(error.localizedDescription, privacy: .public)")
            }
            running = false
            nudge()  // 積壓續跑 / 重設 idle timer
        }
    }
}

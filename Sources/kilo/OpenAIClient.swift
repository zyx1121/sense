import Foundation

/// gpt-5.4-mini chat completions（URLSession 直打 REST，非 streaming）。
/// gpt-5.5 沒有 mini 變體；這代最便宜快的 mini 是 gpt-5.4-mini（$0.75/$4.50 per 1M）。
struct OpenAIClient: Sendable {
    let apiKey: String
    var model = "gpt-5.4-mini"

    private struct Message: Codable { let role: String; let content: String }
    private struct Request: Codable { let model: String; let messages: [Message] }
    private struct Response: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let choices: [Choice]
    }

    private static let system =
        "你是會議 / 影片字幕的洞察助手。讀以下逐字稿片段，用繁體中文給 1–2 句重點或洞察，精簡、直接講結論、不要前言。"

    func summarize(_ transcript: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(model: model, messages: [
            Message(role: "system", content: Self.system),
            Message(role: "user", content: transcript),
        ]))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "?"
            throw NSError(domain: "OpenAI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.choices.first?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

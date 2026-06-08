import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// 階段2 baseline：本地整理模型（Qwen3-1.7B-4bit via MLX），對照雲端 gpt-5.4-mini。
/// 載入非同步（首次從 HF 下載 ~1GB 量化權重）；ready 後 polisher 才對照跑。
/// 每 chunk 無狀態（new ChatSession，不讓上段脈絡污染下段），temperature 0（整理要確定性、不創意）。
@MainActor
final class LocalPolisher {
    private var container: ModelContainer?
    private(set) var ready = false

    /// 背景載入（下載 + 預熱）。失敗就靜默停用，不影響雲端整理。
    func load() {
        Task {
            do {
                Telemetry.polish.info("local model 載入中（首次會下載 Qwen3-1.7B-4bit ~1GB）…")
                container = try await #huggingFaceLoadModelContainer(
                    configuration: LLMRegistry.qwen3_1_7b_4bit)
                ready = true
                Telemetry.polish.info("local model ready: Qwen3-1.7B-4bit")
            } catch {
                Telemetry.polish.error("local model 載入失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 整理一段（無狀態），回（整理後文字, 耗時 ms）；沒 ready / 失敗回 nil。
    func polish(chunk: String, locale: String) async -> (text: String, ms: Int)? {
        guard let container else { return nil }
        let start = Date()
        let session = ChatSession(
            container,
            instructions: Self.instructions(locale),
            generateParameters: GenerateParameters(maxTokens: 1000, temperature: 0))
        do {
            let out = try await session.respond(to: chunk)
            return (out.trimmingCharacters(in: .whitespacesAndNewlines),
                    Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            Telemetry.polish.error("local polish 失敗: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 跟 TranscriptPolisher 同一套整理規則（baseline 要公平對照）。
    private static func instructions(_ locale: String) -> String {
        locale.hasPrefix("zh")
            ? """
            你是逐字稿整理員。使用者訊息是一段中文語音辨識的原始逐字稿，整理它：補上標點符號；\
            修正辨識錯字（同音字、形近字、語境不通的字），依上下文還原最合理的說法，真的無法判斷才保留原字，\
            不要改寫句構、不要潤飾；輸出必須是中文，絕對不要翻譯；不增刪語意、不摘要、不回答問題、不加任何說明或標記。\
            只輸出整理後的文字本身。
            """
            : """
            You clean up a raw English speech-recognition transcript: add punctuation; \
            fix mis-recognitions (homophones, garbled words) using context, keep the original wording when \
            genuinely undecidable, do not paraphrase; the output MUST be English, NEVER translate; do not add, \
            remove, or summarize content; no comments or labels. Output only the cleaned text itself.
            """
    }
}

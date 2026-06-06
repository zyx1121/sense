import Foundation

struct CodexResult: Sendable {
    let text: String
}

/// codex exec 當 agent engine：workspace-write 圈在 workdir、小 model + minimal reasoning 求快。
/// - 用 `/bin/zsh -lc` 跑：codex 在 fnm shim，GUI subprocess 的 PATH 看不到，login shell 才載得到。
/// - 帶 CODEX_API_KEY（從 Keychain）：避開 ChatGPT 登入的 rate-limit。
/// - 指令走 env（不拼進命令字串避免 injection）；逐字稿走 stdin；結果讀 `-o` 檔。
struct CodexAgent: Sendable {
    let workdir: String
    let apiKey: String?
    var model = "gpt-5.4-mini"

    func run(instruction: String, transcript: String) async throws -> CodexResult {
        let out = NSTemporaryDirectory() + "kilo-codex-\(UUID().uuidString).txt"
        let cmd = """
            codex exec -C '\(workdir)' --skip-git-repo-check \
            -s workspace-write -m \(model) \
            -c model_reasoning_effort=low -c approval_policy=never \
            -o '\(out)' "$KILO_INSTRUCTION"
            """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        env["KILO_INSTRUCTION"] = instruction
        if let apiKey { env["CODEX_API_KEY"] = apiKey }
        proc.environment = env

        let stdin = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardError = stderr
        proc.standardOutput = FileHandle.nullDevice  // 結果走 -o，stdout 噪音丟掉

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { p in
                defer { try? FileManager.default.removeItem(atPath: out) }
                guard p.terminationStatus == 0 else {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    cont.resume(throwing: NSError(
                        domain: "Codex", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "codex exec failed" : err]))
                    return
                }
                let text = (try? String(contentsOfFile: out, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: CodexResult(text: text))
            }
            do {
                try proc.run()
                stdin.fileHandleForWriting.write(Data(transcript.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

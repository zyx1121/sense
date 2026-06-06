import Foundation

/// codex exec --json 吐出的事件，餵 UI 即時顯示。
enum CodexEvent: Sendable {
    case step(id: String, title: String, running: Bool, failed: Bool)  // tool / exec 步驟
    case message(String)                                               // agent 一則完整回覆
}

/// codex exec 當 agent engine：workspace-write 圈在 workdir、小 model + minimal reasoning 求快。
/// - 用 `/bin/zsh -lc` 跑：codex 在 fnm shim，GUI subprocess 的 PATH 看不到，login shell 才載得到。
/// - 帶 CODEX_API_KEY（從 Keychain）：避開 ChatGPT 登入的 rate-limit。
/// - 指令走 env（不拼進命令字串避免 injection）；逐字稿走 stdin（codex 接成 `<stdin>` block）。
/// - `--json`：stdout 每行一個 JSONL event（item.started/completed、turn.*），邊到邊 parse 邊 yield。
struct CodexAgent: Sendable {
    let workdir: String
    let apiKey: String?
    var model = "gpt-5.4-mini"

    func stream(instruction: String, transcript: String) -> AsyncThrowingStream<CodexEvent, Error> {
        let (events, cont) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
        let cmd = """
            codex exec --json -C '\(workdir)' --skip-git-repo-check \
            -s workspace-write -m \(model) \
            -c model_reasoning_effort=low -c approval_policy=never "$KILO_INSTRUCTION"
            """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        env["KILO_INSTRUCTION"] = instruction
        if let apiKey { env["CODEX_API_KEY"] = apiKey }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // exit status 走 AsyncStream，不用 waitUntilExit 卡 cooperative thread
        let (exitStream, exitCont) = AsyncStream<Int32>.makeStream()
        proc.terminationHandler = { p in
            exitCont.yield(p.terminationStatus)
            exitCont.finish()
        }

        Task {
            do {
                try proc.run()
                stdin.fileHandleForWriting.write(Data(transcript.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                cont.finish(throwing: error)
                return
            }

            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    for ev in Self.parse(line) { cont.yield(ev) }
                }
            } catch {
                proc.terminate()
                cont.finish(throwing: error)
                return
            }

            var status: Int32 = 0
            for await s in exitStream { status = s }
            if status != 0 {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !err.isEmpty {
                    cont.finish(throwing: NSError(
                        domain: "Codex", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: err]))
                    return
                }
                // stderr 空的非零退出：turn.failed event 已帶過錯誤，正常收尾
            }
            cont.finish()
        }
        return events
    }

    /// 一行 JSONL → 0..n 個 CodexEvent。schema：exec output v2（probe 實測 codex-cli 0.136）。
    private static func parse(_ line: String) -> [CodexEvent] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }

        switch type {
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  let id = item["id"] as? String else { return [] }
            let done = type == "item.completed"
            switch itemType {
            case "agent_message":
                guard done, let text = item["text"] as? String, !text.isEmpty else { return [] }
                return [.message(text)]
            case "command_execution":
                let cmd = prettyCommand(item["command"] as? String ?? "")
                let failed = done && (item["exit_code"] as? Int ?? 0) != 0
                return [.step(id: id, title: "$ \(cmd)", running: !done, failed: failed)]
            case "file_change":
                return [.step(id: id, title: "✎ 修改檔案", running: !done, failed: false)]
            case "mcp_tool_call":
                let name = item["tool"] as? String ?? "tool"
                return [.step(id: id, title: "⚙ \(name)", running: !done, failed: false)]
            case "web_search":
                let q = item["query"] as? String ?? ""
                return [.step(id: id, title: "🔍 \(q)", running: !done, failed: false)]
            case "error":
                let msg = item["message"] as? String ?? "agent error"
                return [.message("⚠️ \(msg)")]
            case "reasoning":
                return []  // low effort 幾乎不出，出了也不占版面
            default:
                return done ? [] : [.step(id: id, title: itemType, running: true, failed: false)]
            }
        case "turn.failed":
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "turn failed"
            return [.message("⚠️ \(msg)")]
        default:
            return []  // thread.started / turn.started / turn.completed
        }
    }

    /// codex 的 command 多包一層 `/bin/zsh -lc '…'`，顯示時剝掉。
    private static func prettyCommand(_ raw: String) -> String {
        var s = raw
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc ", "sh -c "]
        where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        if s.count >= 2, (s.first == "'" && s.last == "'") || (s.first == "\"" && s.last == "\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s.count > 60 ? String(s.prefix(60)) + "…" : s
    }
}

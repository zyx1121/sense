import Foundation

/// codex exec --json 吐出的事件，餵 UI 即時顯示。
enum CodexEvent: Sendable {
    case thread(String)                                                // session id，下輪 resume 用
    case step(id: String, title: String, running: Bool, failed: Bool)  // tool / exec 步驟
    case message(String)                                               // agent 一則完整回覆
}

/// codex exec 當 agent engine：workspace-write 圈在 workdir、小 model + minimal reasoning 求快。
/// - 用 `/bin/zsh -lc` 跑：codex 在 fnm shim，GUI subprocess 的 PATH 看不到，login shell 才載得到。
/// - 帶 CODEX_API_KEY（從 Keychain）：避開 ChatGPT 登入的 rate-limit。
/// - prompt（指令 + 逐字稿）整包走 env，不拼進命令字串避免 injection。
///   不用 stdin：`exec resume` 模式 stdin 不會接進 prompt（實測 codex-cli 0.136），統一走 env。
/// - `--json`：stdout 每行一個 JSONL event（item.started/completed、turn.*），邊到邊 parse 邊 yield。
/// - history：`thread.started` 的 id 由呼叫端記下，下輪 `exec resume <id>` 續同一個 session；
///   resume 不收 `-s`/`-C`，sandbox 與 workdir 從原 session 繼承。
struct CodexAgent: Sendable {
    let workdir: String
    let apiKey: String?
    var model = "gpt-5.4-mini"

    /// GUI app 從 Finder/launchd 啟動是貧瘠環境：`zsh -lc`（login 非 interactive）不載 ~/.zshrc，
    /// 撈不到 fnm / codex 的 PATH → `command not found: codex`。啟動撈一次 interactive login shell 的
    /// 完整 PATH 快取、執行時注入 — 每輪 codex 仍走乾淨 `-lc`，不付載整份 .zshrc + plugin 的成本。
    static let shellPath: String = {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ilc", "echo __KILOPATH__$PATH"]  // 標記前綴：從 .zshrc 的 history/plugin 雜訊裡撈 PATH 行
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return fallback }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = out.split(separator: "\n").first(where: { $0.contains("__KILOPATH__") }),
              let range = line.range(of: "__KILOPATH__") else { return fallback }
        let path = String(line[range.upperBound...])
        return path.isEmpty ? fallback : path
    }()

    func stream(instruction: String, transcript: String,
                resume threadID: String? = nil,
                images: [String] = []) -> AsyncThrowingStream<CodexEvent, Error> {
        let (events, cont) = AsyncThrowingStream<CodexEvent, Error>.makeStream()

        // workspace 導覽只在 fresh session 給 — resume 時 codex 記得，不重複燒 token。
        // 這段讓「上週看的那個影片講什麼」答得出來：歷史逐字稿就在它的 workspace。
        let orientation = threadID == nil
            ? "（你的 workspace ~/.kilo：transcripts/YYYY-MM-DD.md 是逐字稿歷史（含時間與來源標題）、"
                + "notes/ 是你寫過的筆記、captures/ 是使用者圈選的截圖。"
                + "被問到「之前 / 上週 / 那個影片」這類過去的事，先 grep transcripts 再回答。）\n\n"
            : ""

        // 逐字稿包進 prompt（resume 時 codex 記得舊的，但新語音只在這份 tail 裡）
        let prompt = transcript.isEmpty
            ? orientation + instruction
            : "\(orientation)\(instruction)\n\n（最新逐字稿片段，可能與前次部分重疊）\n\(transcript)"

        // 截圖走 -i（fresh / resume 都收）；path 是自家產的 ~/.kilo/captures/*.png，單引號包安全
        let imageFlags = images.map { "-i '\($0)'" }.joined(separator: " ")
        let common = "\(imageFlags) -m \(model) -c model_reasoning_effort=low -c approval_policy=never"
        let cmd: String
        if let threadID {
            cmd = "codex exec resume '\(threadID)' --json --skip-git-repo-check \(common) \"$KILO_PROMPT\""
        } else {
            cmd = """
                codex exec --json -C '\(workdir)' --skip-git-repo-check \
                -s workspace-write \(common) "$KILO_PROMPT"
                """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.shellPath  // 注入 interactive shell 的完整 PATH，GUI app 才找得到 codex / node
        env["KILO_PROMPT"] = prompt
        if let apiKey { env["CODEX_API_KEY"] = apiKey }
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = FileHandle.nullDevice
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
        case "thread.started":
            // UUID 字元集檢查：id 會被拼進下輪 resume 命令，不吃奇怪輸出
            guard let id = obj["thread_id"] as? String,
                  !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return [] }
            return [.thread(id)]
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
            return []  // turn.started / turn.completed
        }
    }

    /// codex 的 command 多包一層 `/bin/zsh -lc '…'`，顯示時剝掉。
    private static func prettyCommand(_ raw: String) -> String {
        var s = raw
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc ", "sh -c ", "/bin/zsh -c ", "/bin/bash -c "]
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

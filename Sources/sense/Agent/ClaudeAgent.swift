import Foundation

/// claude CLI（Claude Code headless）stream-json 吐出的事件，餵 UI 即時顯示。
enum AgentEvent: Sendable {
    case thread(String)                                                // session id，下輪 resume 用
    case step(id: String, title: String, running: Bool, failed: Bool)  // 工具呼叫（tool_use → tool_result）
    case message(String)                                               // agent 最終完整回覆
}

/// claude CLI 當 agent engine：headless（`-p`）+ stream-json 事件流。
/// - 用 `/bin/zsh -lc` 跑：claude 走 node/fnm shim，GUI subprocess 的 PATH 看不到，login shell 才載得到。
/// - 用本機既有登入（Claude Code 的 OAuth / 訂閱），不帶任何 API key。
/// - prompt（指令 + 逐字稿 + 截圖路徑）走 stdin，不拼進命令字串 → 天生免 injection、免引號地獄。
/// - `--output-format stream-json --verbose`：stdout 每行一個 JSONL event，邊到邊 parse 邊 yield。
/// - `--permission-mode bypassPermissions`：非互動自動核准工具（headless 不彈權限詢問）。
/// - **不指定 --model**：繼承使用者預設模型（最強）。
/// - history：`init` event 的 session_id 由呼叫端記下，下輪 `--resume <id>` 續同一個 session；
///   workspace 方位指引由 cwd（~/.sense）下的 CLAUDE.md 自動載入，fresh / resume 都一致拿到
///   （這是 memory 機制、不是 settings，不受下面的隔離旗標影響，實測 fresh + resume 都仍讀得到）。
///
/// **環境隔離**（實測 `claude --help` 逐一驗證，不用印象）：不隔離的話 claude 預設會掛載使用者整套
/// user-scope 設定（`~/.claude/plugins` 全部 marketplace plugin + `~/.claude.json` 的 MCP servers），
/// 一輪 hello 就因為系統 prompt 灌爆到 $0.34、且工具面遠超這個「感官」agent 該碰的範圍。組合：
/// - `--setting-sources project`：只吃 project/local 設定，排除 user scope（plugins/MCP 全部歸零 —
///   實測 init event 的 `mcp_servers` / `plugins` 從一長串變 `[]`）
/// - `--tools Read,Bash,Grep,Glob,Write`：白名單只留讀寫檔案 + 執行 + 搜尋，不用 `--bare`
///   （`--bare` 連 CLAUDE.md auto-discovery 都關，會連工作區方位指引一起丟掉）
/// - `--disable-slash-commands`：連內建 skills 都關（實測 skills 從一串內建清單變 `[]`）
/// 三者疊加，實測穩態（prompt cache 命中後）單輪成本從 $0.34 降到 $0.008–0.02（同一句 hello 前後對比）。
struct ClaudeAgent: Sendable {
    let workdir: String

    /// GUI app 從 Finder/launchd 啟動是貧瘠環境：`zsh -lc`（login 非 interactive）不載 ~/.zshrc，
    /// 撈不到 node / claude 的 PATH → `command not found: claude`。啟動撈一次 interactive login shell 的
    /// 完整 PATH 快取、執行時注入 — 每輪 claude 仍走乾淨 `-lc`，不付載整份 .zshrc + plugin 的成本。
    static let shellPath: String = {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ilc", "echo __SENSEPATH__$PATH"]  // 標記前綴：從 .zshrc 的 history/plugin 雜訊裡撈 PATH 行
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return fallback }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = out.split(separator: "\n").first(where: { $0.contains("__SENSEPATH__") }),
              let range = line.range(of: "__SENSEPATH__") else { return fallback }
        let path = String(line[range.upperBound...])
        return path.isEmpty ? fallback : path
    }()

    /// claude binary 是否在 PATH 上 — main.swift 用它 gate agent（缺 CLI → agent 停用，字幕/逐字稿照常）。
    static var isAvailable: Bool {
        let fm = FileManager.default
        return shellPath.split(separator: ":").contains { fm.isExecutableFile(atPath: "\($0)/claude") }
    }

    func stream(instruction: String, transcript: String,
                resume sessionID: String? = nil,
                images: [String] = []) -> AsyncThrowingStream<AgentEvent, Error> {
        let (events, cont) = AsyncThrowingStream<AgentEvent, Error>.makeStream()

        // 逐字稿包進 prompt（resume 時 claude 記得舊的，但新語音只在這份 tail 裡）；
        // 截圖只給路徑，讓 claude 用 Read 工具自己讀（Read 原生吃圖）。
        var prompt = transcript.isEmpty
            ? instruction
            : "\(instruction)\n\n（最新逐字稿片段，可能與前次部分重疊）\n\(transcript)"
        if !images.isEmpty {
            prompt += "\n\n（使用者圈選的截圖，用 Read 工具讀這些路徑）\n" + images.joined(separator: "\n")
        }

        // 命令字串只含受控旗標（session id 已做字元集驗證），使用者自由文字全走 stdin。
        var cmd = """
            claude -p --output-format stream-json --verbose --permission-mode bypassPermissions \
            --setting-sources project --tools Read,Bash,Grep,Glob,Write --disable-slash-commands
            """
        if let sessionID { cmd += " --resume '\(sessionID)'" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: workdir)  // cwd = workspace，claude 自動載此處 CLAUDE.md
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.shellPath  // 注入 interactive shell 的完整 PATH，GUI app 才找得到 claude / node
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
            } catch {
                cont.finish(throwing: error)
                return
            }

            // prompt 走 stdin：另一條 task 灌入避免大 transcript 撐爆 pipe 而與 stdout 讀取死結
            let promptData = Data(prompt.utf8)
            let writer = Task.detached {
                let h = stdin.fileHandleForWriting
                try? h.write(contentsOf: promptData)
                try? h.close()
            }

            var stepTitles: [String: String] = [:]  // tool_use id → 顯示標題，tool_result 回來時沿用
            var gotMessage = false
            var pendingError: Error?
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let obj = Self.decode(line), let type = obj["type"] as? String else { continue }
                    switch type {
                    case "system":
                        // session id 只認 init（其他 system 事件如 hook 也帶 session_id，不重複抓）
                        if obj["subtype"] as? String == "init",
                           let id = obj["session_id"] as? String, !id.isEmpty,
                           id.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
                            cont.yield(.thread(id))
                        }
                    case "assistant":
                        for block in Self.contentBlocks(obj) where block["type"] as? String == "tool_use" {
                            guard let id = block["id"] as? String else { continue }
                            let title = Self.prettyTool(name: block["name"] as? String ?? "tool",
                                                        input: block["input"] as? [String: Any] ?? [:])
                            stepTitles[id] = title
                            cont.yield(.step(id: id, title: title, running: true, failed: false))
                        }
                    case "user":
                        for block in Self.contentBlocks(obj) where block["type"] as? String == "tool_result" {
                            guard let id = block["tool_use_id"] as? String else { continue }
                            let failed = block["is_error"] as? Bool ?? false
                            cont.yield(.step(id: id, title: stepTitles[id] ?? "tool",
                                             running: false, failed: failed))
                        }
                    case "result":
                        let text = obj["result"] as? String ?? ""
                        let isErr = (obj["subtype"] as? String != "success") || (obj["is_error"] as? Bool == true)
                        if isErr {
                            let msg = text.isEmpty ? (obj["subtype"] as? String ?? "claude error") : text
                            pendingError = NSError(domain: "Claude", code: 1,
                                                   userInfo: [NSLocalizedDescriptionKey: msg])
                        } else if !text.isEmpty {
                            gotMessage = true
                            cont.yield(.message(text))
                        }
                    default:
                        break  // rate_limit_event / stream_event 等，忽略
                    }
                }
            } catch {
                _ = await writer.value
                proc.terminate()
                cont.finish(throwing: error)
                return
            }
            _ = await writer.value

            var status: Int32 = 0
            for await s in exitStream { status = s }
            if let pendingError {
                cont.finish(throwing: pendingError)
                return
            }
            if status != 0, !gotMessage {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !err.isEmpty {
                    cont.finish(throwing: NSError(
                        domain: "Claude", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: err]))
                    return
                }
            }
            cont.finish()
        }
        return events
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }

    /// assistant / user 事件的 message.content 陣列（stream-json 把每則 message 包一層 `message`）。
    private static func contentBlocks(_ obj: [String: Any]) -> [[String: Any]] {
        guard let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return [] }
        return content
    }

    /// tool_use → 一行可讀的步驟標題（`$ cmd` / ✎ / 🔍 的視覺語言）。
    private static func prettyTool(name: String, input: [String: Any]) -> String {
        func base(_ p: String) -> String { (p as NSString).lastPathComponent }
        let title: String
        switch name {
        case "Bash":       title = "$ " + (input["command"] as? String ?? "")
        case "Read":       title = "📖 " + base(input["file_path"] as? String ?? "")
        case "Write", "Edit", "NotebookEdit":
                           title = "✎ " + base(input["file_path"] as? String ?? "")
        case "Grep", "Glob":
                           title = "🔍 " + (input["pattern"] as? String ?? "")
        case "WebSearch":  title = "🔍 " + (input["query"] as? String ?? "")
        case "WebFetch":   title = "🌐 " + (input["url"] as? String ?? "")
        default:           title = "⚙ " + name
        }
        let clean = title.replacingOccurrences(of: "\n", with: " ")
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }
}

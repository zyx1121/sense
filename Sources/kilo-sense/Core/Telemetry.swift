import OSLog

/// 集中的結構化日誌。
/// 即時看：`log stream --info --predicate 'subsystem == "tw.zyx.kilo"' --style compact`（或 `make logs`）。
enum Telemetry {
    static let asr = Logger(subsystem: "tw.zyx.kilo", category: "asr")
    static let agent = Logger(subsystem: "tw.zyx.kilo", category: "agent")
    static let polish = Logger(subsystem: "tw.zyx.kilo", category: "polish")
    static let shake = Logger(subsystem: "tw.zyx.kilo", category: "shake")
    static let ptt = Logger(subsystem: "tw.zyx.kilo", category: "ptt")
    static let meeting = Logger(subsystem: "tw.zyx.kilo", category: "meeting")
}

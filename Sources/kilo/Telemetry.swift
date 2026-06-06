import OSLog

/// 集中的結構化日誌 + signpost。
/// 即時看：`log stream --predicate 'subsystem == "tw.zyx.kilo"' --style compact`
/// 量延遲：Instruments 的 os_signpost。
enum Telemetry {
    static let asr = Logger(subsystem: "tw.zyx.kilo", category: "asr")
    static let summary = Logger(subsystem: "tw.zyx.kilo", category: "summary")
    static let polish = Logger(subsystem: "tw.zyx.kilo", category: "polish")
    static let shake = Logger(subsystem: "tw.zyx.kilo", category: "shake")
    static let signposter = OSSignposter(subsystem: "tw.zyx.kilo", category: "summary")
}

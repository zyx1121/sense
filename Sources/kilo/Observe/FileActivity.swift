import Foundation

/// 軌3：FSEvents 監控使用者活躍目錄的檔案操作（新增/改名/刪除/修改）。
/// metadata-only（只給路徑、不讀內容）→ 歷史上 protected 三夾免 Full Disk Access、
/// 不跳 TCC、背景可用。代價：拿不到「是哪個 app 改的」（要 PID 得 EndpointSecurity，門檻過高，不走）。
/// callback 在自家 queue 觸發，hop 回 MainActor 灌進 ObservationStore。
@MainActor
final class FileActivity {
    private let store: ObservationStore
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "tw.zyx.kilo.fsevents")

    /// 監控 ~/Desktop ~/Documents ~/Downloads — 使用者「動檔案」最常見的地方。
    private let roots = ["Desktop", "Documents", "Downloads"].map { NSHomeDirectory() + "/" + $0 }

    init(store: ObservationStore) { self.store = store }

    func start() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &ctx, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,   // 1s coalescing：連續同檔操作合併，不洗版
            flags
        ) else {
            Telemetry.observe.error("FSEventStream 建立失敗")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// @convention(c) callback 不能 capture — self 透過 ctx.info 傳進來。
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let me = Unmanaged<FileActivity>.fromOpaque(info).takeUnretainedValue()
        let ptr = paths.bindMemory(to: UnsafePointer<CChar>.self, capacity: count)
        var batch: [(String, FSEventStreamEventFlags)] = []
        for i in 0..<count { batch.append((String(cString: ptr[i]), flags[i])) }
        Task { @MainActor in me.handle(batch) }
    }

    private func handle(_ batch: [(path: String, flags: FSEventStreamEventFlags)]) {
        for (path, flags) in batch {
            guard let summary = Self.summarize(path: path, flags: flags) else { continue }
            store.observeFile(summary)
        }
    }

    /// 路徑 + flag → 一句人類可讀。濾掉隱藏檔/暫存檔；flag 不精確（同操作可能多發），只能 best-effort 判型。
    private static func summarize(path: String, flags: FSEventStreamEventFlags) -> String? {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !name.hasSuffix("~"), !path.contains("/.") else { return nil }
        let f = Int(flags)
        let short = abbreviate(path)
        if f & kFSEventStreamEventFlagItemRenamed != 0 { return "改名 \(short)" }
        if f & kFSEventStreamEventFlagItemCreated != 0 { return "新增 \(short)" }
        if f & kFSEventStreamEventFlagItemRemoved != 0 { return "刪除 \(short)" }
        if f & kFSEventStreamEventFlagItemModified != 0 { return "修改 \(short)" }
        return nil   // 純權限/屬性變動不報
    }

    /// home 前綴縮成 ~。
    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

import AppKit
import CoreAudio

/// 軌2b（誰在發聲）：用 Core Audio 的 process-object list 列舉「正在輸出音訊」的 app。
/// 回答「聲音從哪裡來」— 不只前景 app（軌1 看的是焦點），是實際在發聲的 process（可能在背景播）。
///
/// macOS 14.4+ 的 HAL process API。**純查 metadata**（bundleID / isRunningOutput），不讀任何音訊
/// sample → 不需 NSAudioCaptureUsageDescription（那是建 process tap 真的擷取音訊才要的權限）。
/// HAL 沒有單一 listener 能監聽「發聲狀態變化」（要 per-process 各加），故輪詢；property 查詢很輕。
@MainActor
final class AudioActivity {
    private let store: ObservationStore
    private var timer: Timer?
    private let system = AudioObjectID(kAudioObjectSystemObject)

    init(store: ObservationStore) { self.store = store }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        Telemetry.observe.info("軌2b 音訊來源追蹤啟動（輪詢 5s）")
    }

    private func poll() {
        store.observeAudible(audibleApps())
    }

    /// 正在輸出音訊的 app 顯示名（bundleID → NSRunningApplication；查不到就用 bundleID）。
    private func audibleApps() -> [String] {
        var names: [String] = []
        for obj in processList() where readBool(obj, kAudioProcessPropertyIsRunningOutput) {
            guard let bundleID = readString(obj, kAudioProcessPropertyBundleID) else { continue }
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName ?? bundleID
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func processList() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private func readBool(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr else { return nil }
        var cf = "" as CFString
        let err = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard err == noErr else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }
}

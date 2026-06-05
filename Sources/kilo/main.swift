import Foundation
import Speech

// M1a：--locales 探測語言支援（保留，免權限）
func dumpLocales() async {
    let supported = Array(await SpeechTranscriber.supportedLocales)
    let installed = Array(await SpeechTranscriber.installedLocales)
    func dump(_ title: String, _ ls: [Locale]) {
        print("=== \(title) (\(ls.count)) ===")
        for id in ls.map({ $0.identifier }).sorted() { print("  \(id)") }
    }
    dump("supportedLocales", supported)
    dump("installedLocales", installed)
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

if CommandLine.arguments.contains("--locales") {
    await dumpLocales()
    exit(0)
}

// M1b：系統音訊 (ScreenCaptureKit) → SpeechAnalyzer(zh-TW) → console 字幕
let transcriber = Transcriber(locale: Locale(identifier: "zh-TW"))
let source = SystemAudioSource()

log("kilo — 系統音訊即時字幕 (zh-TW)。Ctrl-C 結束。")

// Ctrl-C 優雅收尾（global queue，不依賴 main runloop）
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler {
    Task { await source.stop(); try? await transcriber.finish() }
}
sigint.resume()

do {
    try await transcriber.setUp()
    let audio = try await source.start()
    log("聽取中…")
    for await buffer in audio {
        try await transcriber.stream(buffer)
    }
    log("結束。")
} catch {
    log("error: \(error)")
    exit(1)
}

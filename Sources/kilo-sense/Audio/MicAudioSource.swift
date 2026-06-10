import AVFoundation

enum MicAudioError: LocalizedError {
    case permissionDenied
    case noInputFormat

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "麥克風權限未授權（系統設定 → 隱私權與安全性 → 麥克風）"
        case .noInputFormat: "麥克風輸入未就緒（裝置格式無效）"
        }
    }
}

/// AVAudioEngine 麥克風擷取 — PTT 與會議模式的「我」聲源。
/// 與 SystemAudioSource 同一個 AudioSource 介面；start/stop 可重複循環（每次 start 換新 stream）。
final class MicAudioSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<PCMBuffer>.Continuation?

    func start() async throws -> AsyncStream<PCMBuffer> {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MicAudioError.permissionDenied
        }
        let input = engine.inputNode
        // mic 原生格式，轉換交給 Transcriber 的 BufferConverter。
        // 剛授權完 / 裝置切換的瞬間 inputNode 可能短暫回報 0 Hz — 拿無效格式 installTap
        // 會丟 ObjC NSException（Swift 接不住，直接閃退；實戰驗屍 2026-06-10）。先驗證 + 短重試。
        var format = input.outputFormat(forBus: 0)
        for _ in 0..<20 where format.sampleRate == 0 || format.channelCount == 0 {
            try? await Task.sleep(for: .milliseconds(100))
            format = input.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicAudioError.noInputFormat
        }
        let (stream, continuation) = AsyncStream<PCMBuffer>.makeStream()
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            self?.continuation?.yield(PCMBuffer(pcm: copy))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.continuation = nil
            throw error
        }
        return stream
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

extension AVAudioPCMBuffer {
    /// tap 回呼的 buffer 跨執行緒前深拷貝（與 SystemAudioSource 的 toPCMBufferCopy 同一條防線）。
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<Int(format.channelCount) { dst[ch].update(from: src[ch], count: frames) }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<Int(format.channelCount) { dst[ch].update(from: src[ch], count: frames) }
        }
        return copy
    }
}

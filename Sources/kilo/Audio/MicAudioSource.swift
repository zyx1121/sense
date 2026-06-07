import AVFoundation

/// 麥克風來源（M3）：AVAudioEngine input tap → PCM stream。
/// 用途是語音指令 — 指令只能從「使用者的嘴」來；系統音訊是「世界的聲音」，
/// 只做逐字稿，否則任何影片喊一聲 kilo 就能對 agent 下指令（injection）。
final class MicAudioSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<PCMBuffer>.Continuation?

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start() async throws -> AsyncStream<PCMBuffer> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let (stream, continuation) = AsyncStream<PCMBuffer>.makeStream()
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // tap 的 buffer 會被 engine 重用 — 深拷貝後才能丟進 async stream
            guard let copy = Self.copy(buffer) else { return }
            self?.continuation?.yield(PCMBuffer(pcm: copy))
        }
        try engine.start()
        return stream
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameCapacity) else { return nil }
        dst.frameLength = src.frameLength
        let bytes = Int(src.frameLength) * Int(src.format.streamDescription.pointee.mBytesPerFrame)
        if let s = src.audioBufferList.pointee.mBuffers.mData,
           let d = dst.audioBufferList.pointee.mBuffers.mData {
            memcpy(d, s, bytes)
        }
        // non-interleaved 多 channel：逐 channel 拷
        if src.format.channelCount > 1, !src.format.isInterleaved,
           let sf = src.floatChannelData, let df = dst.floatChannelData {
            for ch in 0..<Int(src.format.channelCount) {
                memcpy(df[ch], sf[ch], Int(src.frameLength) * MemoryLayout<Float>.size)
            }
        }
        return dst
    }
}

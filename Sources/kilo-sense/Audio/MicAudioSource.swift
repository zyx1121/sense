import AVFoundation

enum MicAudioError: Error {
    case permissionDenied
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
        let format = input.outputFormat(forBus: 0)  // mic 原生格式，轉換交給 Transcriber 的 BufferConverter
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

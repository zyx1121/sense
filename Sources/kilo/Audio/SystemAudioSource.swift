import AVFoundation
import ScreenCaptureKit

enum SystemAudioError: Error {
    case permissionDenied
    case noDisplay
}

/// ScreenCaptureKit 系統音訊擷取（loopback，非麥克風）。
/// CMSampleBuffer→AVAudioPCMBuffer 轉換參考 electron-system-audio-recorder /
/// whisper.cpp discussion #2704（兩個獨立來源逐字一致）。
/// @unchecked Sendable：start/stop 由呼叫端序列化，continuation 在 startCapture 前設妥。
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var continuation: AsyncStream<PCMBuffer>.Continuation?
    private let sampleQueue = DispatchQueue(label: "tw.zyx.kilo.systemaudio")

    func start() async throws -> AsyncStream<PCMBuffer> {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw SystemAudioError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // 不錄自己，避免回授
        config.sampleRate = 16_000  // 源頭直接要 16k mono，省掉 48k→16k 重採樣
        config.channelCount = 1
        config.width = 2                            // 只要音訊，畫面降到最小省資源
        config.height = 2
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        let (audioStream, continuation) = AsyncStream<PCMBuffer>.makeStream()
        self.continuation = continuation
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            // 啟動失敗（-3818 等）要放掉 ref — 留著殭屍 SCStream 會擋住下一次 retry
            self.stream = nil
            self.continuation = nil
            throw error
        }
        return audioStream
    }

    func stop() async {
        try? await stream?.stopCapture()
        continuation?.finish()
        stream = nil
        continuation = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.toPCMBufferCopy() else { return }
        continuation?.yield(PCMBuffer(pcm: pcm))  // deep copy 過，跨 queue 安全
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("stream stopped: \(error)\n".utf8))
        continuation?.finish()
    }
}

extension CMSampleBuffer {
    /// 轉成自有記憶體的 AVAudioPCMBuffer（深拷貝；bufferListNoCopy 跨 queue 不安全）。
    func toPCMBufferCopy() -> AVAudioPCMBuffer? {
        guard let asbd = formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                         channels: asbd.mChannelsPerFrame) else { return nil }
        return try? withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let noCopy = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: audioBufferList.unsafePointer),
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: noCopy.frameLength)
            else { return nil }
            copy.frameLength = noCopy.frameLength
            let frames = Int(noCopy.frameLength)
            if let src = noCopy.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(format.channelCount) { dst[ch].update(from: src[ch], count: frames) }
            }
            return copy
        }
    }
}

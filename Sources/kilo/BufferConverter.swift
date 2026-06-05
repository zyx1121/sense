@preconcurrency import AVFoundation
import Foundation
import os

/// 把來源 PCM buffer 轉成 analyzer 要求的 format（SCK 48k/stereo → analyzer format）。
/// 取自 FluidInference/swift-scribe BufferConversion.swift。
final class BufferConverter {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none  // 犧牲頭幾個 sample 品質，換取不要 timestamp drift
        }
        guard let converter else { throw Error.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                               frameCapacity: frameCapacity) else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        let processed = OSAllocatedUnfairLock(initialState: false)
        let status = converter.convert(to: outBuffer, error: &nsError) { _, inputStatus in
            let wasProcessed = processed.withLock { p -> Bool in let w = p; p = true; return w }
            inputStatus.pointee = wasProcessed ? .noDataNow : .haveData
            return wasProcessed ? nil : buffer
        }
        guard status != .error else { throw Error.conversionFailed(nsError) }
        return outBuffer
    }
}

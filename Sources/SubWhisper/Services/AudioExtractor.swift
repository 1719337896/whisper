import Foundation
import AVFoundation

/// 音频抽取：把视频/任意音频转成 Whisper 要求的 16kHz 单声道 WAV
enum AudioExtractor {

    enum ExtractError: LocalizedError {
        case noAudioTrack
        case exportFailed(String)
        case readerFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "该文件不包含音轨"
            case .exportFailed(let msg): return "音轨导出失败：\(msg)"
            case .readerFailed: return "无法读取该媒体文件"
            }
        }
    }

    /// 目标音频参数：Whisper 官方要求 16kHz 单声道
    private static let targetSampleRate: Double = 16000
    private static let targetChannels: UInt32 = 1

    /// 从任意媒体文件抽取音频，输出 16kHz mono WAV 到临时目录
    static func extractAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        // 确认有音轨
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ExtractError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("subwhisper-audio-\(UUID().uuidString).wav")

        // 用 AVAssetReader 手工转为 16kHz mono PCM，避免 AVAssetExportSession 的格式限制
        try await convertToWAV(asset: asset, outputURL: outputURL)
        return outputURL
    }

    /// 使用 AVAssetReader + AVAssetWriter 做重采样与声道下混
    private static func convertToWAV(asset: AVURLAsset, outputURL: URL) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExtractError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)

        // 输出设置：16kHz / 1 声道 / 16bit PCM
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else { throw ExtractError.readerFailed }
        reader.add(readerOutput)

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else { throw ExtractError.readerFailed }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw ExtractError.exportFailed(writer.error?.localizedDescription ?? "无法启动读写")
        }
        writer.startSession(atSourceTime: .zero)

        // 在后台队列顺序写入
        let queue = DispatchQueue(label: "com.subwhisper.audio.convert")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                    if !writerInput.append(sample) {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            throw ExtractError.exportFailed(reader.error?.localizedDescription ?? "读取中断")
        }
        if writer.status == .failed {
            throw ExtractError.exportFailed(writer.error?.localizedDescription ?? "写入失败")
        }
    }
}

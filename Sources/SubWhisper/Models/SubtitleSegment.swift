import Foundation

/// 单条字幕
struct SubtitleSegment: Identifiable, Hashable {
    let id = UUID()
    var start: Double      // 秒
    var end: Double        // 秒
    var text: String

    /// SRT 时间戳格式：00:00:01,234
    var srtTimestamp: String {
        "\(Self.srtFormat(start)) --> \(Self.srtFormat(end))"
    }

    /// VTT 时间戳格式：00:00:01.234
    var vttTimestamp: String {
        "\(Self.vttFormat(start)) --> \(Self.vttFormat(end))"
    }

    static func srtFormat(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func vttFormat(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

/// 字幕文件格式
enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt = "SRT"
    case vtt = "VTT"
    case txt = "TXT"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .txt: return "txt"
        }
    }

    var displayName: String {
        switch self {
        case .srt: return "SRT 字幕"
        case .vtt: return "WebVTT 字幕"
        case .txt: return "纯文本稿"
        }
    }
}

/// 字幕生成器
enum SubtitleExporter {

    /// 将字幕段落序列化为指定格式
    static func serialize(_ segments: [SubtitleSegment], format: SubtitleFormat, title: String = "SubWhisper") -> String {
        switch format {
        case .srt:
            return serializeSRT(segments)
        case .vtt:
            return serializeVTT(segments)
        case .txt:
            return serializeTXT(segments)
        }
    }

    private static func serializeSRT(_ segments: [SubtitleSegment]) -> String {
        var out = ""
        for (index, seg) in segments.enumerated() {
            out += "\(index + 1)\n"
            out += "\(seg.srtTimestamp)\n"
            out += "\(seg.text)\n\n"
        }
        return out
    }

    private static func serializeVTT(_ segments: [SubtitleSegment]) -> String {
        var out = "WEBVTT\n\n"
        for seg in segments {
            out += "\(seg.vttTimestamp)\n"
            out += "\(seg.text)\n\n"
        }
        return out
    }

    private static func serializeTXT(_ segments: [SubtitleSegment]) -> String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// 写入临时文件并返回 URL（用于分享/导出）
    static func writeToTemporaryFile(_ segments: [SubtitleSegment], format: SubtitleFormat, baseName: String) throws -> URL {
        let content = serialize(segments, format: format)
        let safeName = baseName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).\(format.fileExtension)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

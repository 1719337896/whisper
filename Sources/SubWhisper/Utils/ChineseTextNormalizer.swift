import Foundation

/// 中文文本后处理。
///
/// Whisper 对中文的 tokenizer 是**按字切分**的，经常产出「人工智 能」这类
/// 字间多余空格，标点前后也会有空格。这里做规则化清理。
enum ChineseTextNormalizer {

    /// 判断是否为 CJK 字符（含中文、日文汉字、假名、全角标点）
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,      // CJK 符号与标点
             0x3040...0x309F,      // 平假名
             0x30A0...0x30FF,      // 片假名
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 基本区
             0xF900...0xFAFF,      // CJK 兼容表意
             0xFF00...0xFFEF:      // 全角字符
            return true
        default:
            return false
        }
    }

    /// 全角标点集合：这些符号前后的空格都该去掉
    private static let fullWidthPunctuation: Set<Character> = [
        "，", "。", "、", "；", "：", "？", "！", "“", "”", "‘", "’",
        "（", "）", "《", "》", "〈", "〉", "【", "】", "「", "」", "…", "—"
    ]

    /// 规范化一段识别文本
    static func normalize(_ input: String) -> String {
        var text = input

        // 1. 去掉零宽字符与 BOM
        text = text.replacingOccurrences(of: "\u{200B}", with: "")
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")

        // 2. 合并 CJK 字符之间的空格（核心修复：「人工智 能」→「人工智能」）
        text = removeSpacesBetweenCJK(text)

        // 3. 去掉全角标点前后的空格
        text = removeSpacesAroundFullWidthPunctuation(text)

        // 4. 半角标点转为全角（中文语境）
        text = convertHalfWidthPunctuation(text)

        // 5. 压缩连续空格
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        // 6. 结尾常见幻觉清理
        text = stripKnownHallucinations(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 删除两个 CJK 字符之间的空格
    private static func removeSpacesBetweenCJK(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        result.reserveCapacity(chars.count)

        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c == " " || c == "\u{00A0}" {
                // 找前一个非空格字符与后一个非空格字符
                let prev = result.last
                var j = i
                while j < chars.count, chars[j] == " " || chars[j] == "\u{00A0}" { j += 1 }
                let next = j < chars.count ? chars[j] : nil

                let prevIsCJK = prev.map { ch in
                    ch.unicodeScalars.allSatisfy { isCJK($0) }
                } ?? false
                let nextIsCJK = next.map { ch in
                    ch.unicodeScalars.allSatisfy { isCJK($0) }
                } ?? false

                // 两侧都是 CJK → 丢弃该空格
                if prevIsCJK && nextIsCJK {
                    i = j
                    continue
                }
                // 一侧是 CJK、另一侧是标点 → 也丢弃
                if prevIsCJK, let n = next, fullWidthPunctuation.contains(n) {
                    i = j
                    continue
                }
                if nextIsCJK, let p = prev, fullWidthPunctuation.contains(p) {
                    i = j
                    continue
                }

                result.append(" ")
                i = j
                continue
            }

            result.append(c)
            i += 1
        }
        return result
    }

    /// 去掉全角标点前后的空格
    private static func removeSpacesAroundFullWidthPunctuation(_ text: String) -> String {
        var out = text
        for p in fullWidthPunctuation {
            out = out.replacingOccurrences(of: "\(p) ", with: "\(p)")
            out = out.replacingOccurrences(of: " \(p)", with: "\(p)")
        }
        return out
    }

    /// 中文语境的半角标点转全角。
    /// 仅当句子中 CJK 占比足够高时才转换，避免破坏英文段落。
    private static func convertHalfWidthPunctuation(_ text: String) -> String {
        let total = text.unicodeScalars.count
        guard total > 0 else { return text }
        let cjkCount = text.unicodeScalars.filter { isCJK($0) }.count
        // CJK 占比低于 30% 视为英文语境，不做转换
        guard Double(cjkCount) / Double(total) > 0.3 else { return text }

        var out = text
        // 逗号句号问号叹号：只在两侧非数字时替换（避免破坏 1,000 / 3.14）
        out = replacePunctuationSafely(out, target: ",", replacement: "，")
        out = replacePunctuationSafely(out, target: ".", replacement: "。")
        out = replacePunctuationSafely(out, target: "?", replacement: "？")
        out = replacePunctuationSafely(out, target: "!", replacement: "！")
        out = replacePunctuationSafely(out, target: ";", replacement: "；")
        out = replacePunctuationSafely(out, target: ":", replacement: "：")
        return out
    }

    /// 安全替换：若标点紧邻 ASCII 数字，则保留（处理小数点、千分位）
    private static func replacePunctuationSafely(_ text: String, target: Character, replacement: Character) -> String {
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            guard c == target else {
                out.append(c)
                continue
            }
            let prevIsDigit = i > 0 && chars[i - 1].isASCII && chars[i - 1].isNumber
            let nextIsDigit = i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber
            if prevIsDigit && nextIsDigit {
                out.append(c)          // 3.14 这类保留
            } else if prevIsDigit && target == "." && i == chars.count - 1 {
                out.append(c)
            } else {
                out.append(replacement)
            }
        }
        return out
    }

    /// 清理 Whisper 在静音/片尾的典型幻觉
    private static func stripKnownHallucinations(_ text: String) -> String {
        let patterns = [
            "谢谢观看", "谢谢大家观看", "感谢观看", "感谢您的观看",
            "字幕由.*提供", "字幕志愿者", "请不吝点赞.*",
            "Thanks for watching", "Thank you for watching",
            "字幕組", "字幕组"
        ]
        var out = text
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                out = regex.stringByReplacingMatches(
                    in: out,
                    range: NSRange(out.startIndex..., in: out),
                    withTemplate: ""
                )
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

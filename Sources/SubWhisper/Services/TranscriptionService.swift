import Foundation
import AVFoundation
import CoreMedia
import WhisperKit

/// 转录过程中的阶段状态
enum TranscriptionStage: Equatable {
    case idle
    case downloadingModel(progress: Double, message: String)
    case loadingModel(progress: Double)
    case extractingAudio(progress: Double)
    case transcribing(progress: Double)
    case finished
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .finished, .failed: return false
        default: return true
        }
    }

    var description: String {
        switch self {
        case .idle: return "待命"
        case .downloadingModel(let p, let msg):
            return "下载模型 \(Int((p * 100).rounded()))%\(msg.isEmpty ? "" : " · \(msg)")"
        case .loadingModel(let p): return "加载模型 \(Int((p * 100).rounded()))%"
        case .extractingAudio(let p): return "提取音轨 \(Int((p * 100).rounded()))%"
        case .transcribing(let p): return "识别中 \(Int((p * 100).rounded()))%"
        case .finished: return "完成"
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    var fraction: Double? {
        switch self {
        case .downloadingModel(let p, _), .loadingModel(let p), .extractingAudio(let p), .transcribing(let p):
            return min(max(p, 0), 1)
        default:
            return nil
        }
    }
}

/// 中文优化的提示词预设。
/// 依据社区实测：initial_prompt 能显著改善标点、简繁一致性，
/// 把专有名词喂进去后，人名识别准确率可从 ~72% 提升到 ~94%。
enum ChinesePromptPreset: String, CaseIterable, Identifiable {
    case none = ""
    case simplified = "以下是普通话的句子，请使用简体中文输出，并加上合适的标点符号。"
    case meeting = "这是一段会议记录的录音，请使用标准简体中文输出，准确识别专业术语，并加上标点符号。"
    case interview = "这是一段普通话访谈的逐字稿，请使用简体中文输出，保留口语表达，并加上标点符号。"
    case subtitle = "以下是视频讲解的内容，请使用简体中文输出，加上标点符号。"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不使用提示词"
        case .simplified: return "强制简体 + 加标点"
        case .meeting: return "会议记录"
        case .interview: return "访谈口语"
        case .subtitle: return "视频讲解"
        }
    }
}

@MainActor
final class TranscriptionService: ObservableObject {

    @Published var stage: TranscriptionStage = .idle
    @Published var segments: [SubtitleSegment] = []
    @Published var detectedLanguage: String = ""

    /// 自定义仓库管理（持久化）
    @Published var customModels: [WhisperModel] = []

    private var whisperKit: WhisperKit?
    private var whisperKitLoadedModelID: String?

    /// 提示词未能生效时的说明（非致命，仅提示用户）
    @Published var promptWarning: String?

    /// 已下载到本地的模型存储目录名
    @Published var installedFolders: Set<String> = []

    init() {
        loadCustomModels()
        refreshInstalledModels()
    }

    // MARK: - 路径

    /// 传给 WhisperKit 的 downloadBase（其内部会再拼 models/<repo>/...）
    static var downloadBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 所有模型的父目录。我们不依赖 WhisperKit 的内部命名，
    /// 而是下载完成后把自己的目录建立成符号映射：见 modelDirectory(for:)。
    static var modelsRoot: URL {
        downloadBase.appendingPathComponent("SubWhisperModels", isDirectory: true)
    }

    /// 某个模型在本地的目录
    func modelDirectory(for model: WhisperModel) -> URL {
        Self.modelsRoot.appendingPathComponent(model.storageFolderName, isDirectory: true)
    }

    // MARK: - 模型清单

    /// 全部可选模型（预置 + 用户自定义）
    var allModels: [WhisperModel] {
        WhisperModel.allPresets + customModels
    }

    func refreshInstalledModels() {
        let root = Self.modelsRoot
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        installedFolders = Set(
            contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent)
        )
    }

    /// 是否已下载（以存在 CoreML 模型包为准）
    func isInstalled(_ model: WhisperModel) -> Bool {
        let dir = modelDirectory(for: model)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    // MARK: - 下载

    func downloadModel(_ model: WhisperModel) async {
        stage = .downloadingModel(progress: 0, message: "准备中")
        do {
            // WhisperKit 会下载到 downloadBase/models/<repo>/openai_whisper-<variant>
            _ = try await WhisperKit.download(
                variant: model.variant,
                downloadBase: Self.downloadBase,
                from: model.repo,
                progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard let self else { return }
                        let current = self.stage.fraction ?? 0
                        guard fraction >= current - 0.001 else { return }
                        self.stage = .downloadingModel(
                            progress: fraction,
                            message: model.approximateSize
                        )
                    }
                }
            )

            // 把 WhisperKit 落地的目录搬到我们自己的命名空间，避免仓库间同名冲突
            try relocateDownloadedModel(model)

            refreshInstalledModels()
            stage = .idle
        } catch {
            stage = .failed("模型下载失败：\(error.localizedDescription)")
        }
    }

    /// 在 WhisperKit 的默认落地位置找到刚下载的模型，移动到 modelDirectory(for:)
    private func relocateDownloadedModel(_ model: WhisperModel) throws {
        let target = modelDirectory(for: model)
        try? FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)

        // 若目标已存在（重装），先清掉
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }

        // 优先在 WhisperKit 默认位置找
        let repoSlug = model.repo.replacingOccurrences(of: "/", with: "_")
        let candidates = [
            Self.downloadBase
                .appendingPathComponent("models")
                .appendingPathComponent(repoSlug)
                .appendingPathComponent("openai_whisper-\(model.variant)"),
            Self.downloadBase
                .appendingPathComponent("models")
                .appendingPathComponent(model.repo)
                .appendingPathComponent("openai_whisper-\(model.variant)")
        ]

        for src in candidates where FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.moveItem(at: src, to: target)
            return
        }

        // 兜底：全盘搜一次 openai_whisper-<variant>
        if let found = findDirectory(named: "openai_whisper-\(model.variant)", under: Self.downloadBase) {
            try FileManager.default.moveItem(at: found, to: target)
            return
        }

        throw NSError(
            domain: "SubWhisper",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "下载完成但未找到模型目录，可能被系统清理"]
        )
    }

    /// 在指定目录下递归查找子目录
    private func findDirectory(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }

        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir && url.lastPathComponent == name {
                return url
            }
        }
        return nil
    }

    func deleteModel(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: modelDirectory(for: model))
        if whisperKitLoadedModelID == model.id {
            whisperKit = nil
            whisperKitLoadedModelID = nil
        }
        refreshInstalledModels()
    }

    // MARK: - 自定义仓库

    private static let customModelsKey = "SubWhisper.customModels"

    private func loadCustomModels() {
        guard let data = UserDefaults.standard.data(forKey: Self.customModelsKey),
              let decoded = try? JSONDecoder().decode([WhisperModel].self, from: data) else {
            customModels = []
            return
        }
        customModels = decoded
    }

    private func persistCustomModels() {
        guard let data = try? JSONEncoder().encode(customModels) else { return }
        UserDefaults.standard.set(data, forKey: Self.customModelsKey)
    }

    /// 添加自定义仓库模型。
    /// - Parameters:
    ///   - repo: HuggingFace 仓库，如 "user/my-whisper-coreml"
    ///   - variant: 仓库内模型目录关键词，支持通配符，如 "large-v3*"
    func addCustomModel(repo: String, variant: String, displayName: String) {
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVariant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty, !trimmedVariant.isEmpty else { return }
        guard trimmedRepo.contains("/") else { return }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = WhisperModel(
            repo: trimmedRepo,
            variant: trimmedVariant,
            displayName: name.isEmpty ? "\(trimmedRepo)/\(trimmedVariant)" : name,
            subtitle: "自定义仓库 · \(trimmedRepo)",
            approximateSize: "未知",
            isOfficial: false
        )
        guard !customModels.contains(where: { $0.id == model.id }) else { return }
        customModels.append(model)
        persistCustomModels()
    }

    func removeCustomModel(_ model: WhisperModel) {
        customModels.removeAll { $0.id == model.id }
        persistCustomModels()
    }

    // MARK: - 加载模型

    private func loadModel(_ model: WhisperModel) async throws -> WhisperKit {
        if let kit = whisperKit, whisperKitLoadedModelID == model.id {
            return kit
        }

        stage = .loadingModel(progress: 0.35)
        let dir = modelDirectory(for: model)
        let localPath = FileManager.default.fileExists(atPath: dir.path) ? dir.path : nil

        let config = WhisperKitConfig(
            model: model.variant,
            downloadBase: Self.downloadBase,
            modelRepo: model.repo,
            modelFolder: localPath,
            verbose: false,
            prewarm: true,
            load: true,
            download: true          // 本地缺失时才联网
        )
        let kit = try await WhisperKit(config)
        whisperKit = kit
        whisperKitLoadedModelID = model.id
        return kit
    }

    // MARK: - 主流程

    func transcribe(
        fileURL: URL,
        model: WhisperModel,
        language: String? = nil,
        promptPreset: ChinesePromptPreset = .none,
        customVocabulary: String = "",
        customPrompt: String = ""
    ) async {
        segments = []
        detectedLanguage = ""
        promptWarning = nil
        do {
            // 1. 音轨
            stage = .extractingAudio(progress: 0.08)
            let audioURL = try await AudioExtractor.extractAudio(from: fileURL) { fraction in
                Task { @MainActor in
                    self.stage = .extractingAudio(progress: fraction)
                }
            }

            // 2. 模型
            let kit = try await loadModel(model)

            // 3. 组装提示词并编码为 promptTokens
            //
            // 注意：WhisperKit 的 DecodingOptions 只接受 promptTokens: [Int]?，
            // 没有字符串入口，中文必须先用 tokenizer 编码。
            // 若 tokenizer 尚未就绪，则本次跳过提示词（不影响转录本身），
            // 避免因编码失败中断整个流程。
            let promptText = buildPrompt(
                preset: promptPreset,
                vocabulary: customVocabulary,
                customPrompt: customPrompt
            )
            var promptTokens: [Int]? = nil
            if !promptText.isEmpty {
                if let tokenizer = kit.tokenizer {
                    // Whisper 官方约定：提示词前加一个空格，效果更稳定
                    let encoded = tokenizer.encode(text: " " + promptText)
                    if !encoded.isEmpty {
                        promptTokens = encoded
                    }
                } else {
                    promptWarning = "提示词未生效：模型 tokenizer 未就绪"
                }
            }

            estimatedTotalWindows = max(await audioDuration(of: audioURL) / 30.0, 1)
            stage = .transcribing(progress: 0)

            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language,
                temperature: 0.0,
                temperatureFallbackCount: 5,
                usePrefillPrompt: true,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: true,
                promptTokens: promptTokens,
                chunkingStrategy: .none
            )

            let results: [TranscriptionResult] = try await kit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options,
                callback: { [weak self] progress in
                    Task { @MainActor in
                        self?.updateTranscriptionProgress(progress)
                    }
                    return nil   // Bool?：true = 取消，nil/false = 继续
                }
            )

            // 4. 汇总 + 中文后处理
            var collected: [SubtitleSegment] = []
            for result in results {
                if detectedLanguage.isEmpty, !result.language.isEmpty {
                    detectedLanguage = result.language
                }
                for seg in result.segments {
                    let raw = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { continue }
                    let cleaned = isChineseContext(detectedLanguage)
                        ? ChineseTextNormalizer.normalize(raw)
                        : raw
                    guard !cleaned.isEmpty else { continue }
                    collected.append(
                        SubtitleSegment(
                            start: Double(seg.start),
                            end: Double(seg.end),
                            text: cleaned
                        )
                    )
                }
            }

            segments = preserveTiming(collected).map { seg in
                var item = seg
                item.text = HomophoneCorrector.apply(seg.text, rules: HomophoneCorrector.load())
                return item
            }
            stage = .finished
            if !segments.isEmpty {
                let title = fileURL.deletingPathExtension().lastPathComponent
                _ = try? TranscriptStore.save(
                    segments: segments,
                    title: title,
                    language: detectedLanguage,
                    modelName: model.displayName
                )
            }
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// 是否中文语境（决定要不要跑中文后处理）
    private func isChineseContext(_ languageCode: String) -> Bool {
        languageCode.lowercased().hasPrefix("zh")
    }

    /// 拼接提示词：预设 + 用户自定义专有名词
    private func buildPrompt(preset: ChinesePromptPreset, vocabulary: String, customPrompt: String) -> String {
        var parts: [String] = []
        let custom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            parts.append(custom)
        } else if !preset.rawValue.isEmpty {
            parts.append(preset.rawValue)
        }
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            parts.append(vocab)
        }
        return parts.joined(separator: " ")
    }

    private var estimatedTotalWindows: Double = 1

    private func updateTranscriptionProgress(_ progress: TranscriptionProgress) {
        let done = Double(progress.windowId) + 1
        let fraction = min(done / max(estimatedTotalWindows, 1), 0.99)
        let current = stage.fraction ?? 0
        guard fraction >= current - 0.001 else { return }
        stage = .transcribing(progress: fraction)
    }

    /// 保留模型给出的起止时间，只修正重叠和无效区间。
    private func preserveTiming(_ input: [SubtitleSegment]) -> [SubtitleSegment] {
        let sorted = input.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, seg in
            var item = seg
            let nextStart = index + 1 < sorted.count ? sorted[index + 1].start : item.end
            if item.end <= item.start {
                item.end = item.start + 0.4
            }
            if nextStart > item.start {
                item.end = min(item.end, nextStart)
            }
            if item.end <= item.start {
                item.end = item.start + 0.3
            }
            return item
        }
    }

    func reset() {
        stage = .idle
        segments = []
    }

    private func audioDuration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 30 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 30
    }
}

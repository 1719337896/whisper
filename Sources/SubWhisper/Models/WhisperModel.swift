import Foundation

/// 一个可用的语音识别模型描述。
///
/// 之所以从 enum 改成 struct：需要支持「任意 HuggingFace 仓库 + 任意 variant」，
/// 并且要按仓库隔离存储路径（不同仓库的同名模型不能互相覆盖）。
struct WhisperModel: Identifiable, Hashable, Codable {

    /// HuggingFace 仓库，例如 "argmaxinc/whisperkit-coreml"
    let repo: String
    /// 仓库内的模型目录关键词，传给 WhisperKit 的 `variant`。
    /// 支持通配符，例如 "distil*large-v3"。
    let variant: String
    /// UI 展示名
    let displayName: String
    /// 一句话说明
    let subtitle: String
    /// 大致体积（展示用）
    let approximateSize: String
    /// 是否官方推荐
    let isOfficial: Bool

    var id: String { "\(repo)/\(variant)" }

    /// 本地存储目录名。WhisperKit 下载后目录为 `openai_whisper-<variant>`，
    /// 但为兼容自定义仓库，这里用完整标识做目录名，避免同名冲突。
    var storageFolderName: String {
        let repoSlug = repo.replacingOccurrences(of: "/", with: "_")
        let variantSlug = variant.replacingOccurrences(of: "*", with: "star")
        return "\(repoSlug)__\(variantSlug)"
    }

    /// 该模型在当前设备上是否建议使用（按内存粗判）
    var isViableOnThisDevice: Bool {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        switch variant {
        case let v where v.contains("large"):
            return memoryGB >= 7
        case let v where v.contains("medium"):
            return memoryGB >= 6
        case let v where v.contains("small"):
            return memoryGB >= 4
        default:
            return true
        }
    }

    // MARK: - 官方仓库

    static let officialRepo = "argmaxinc/whisperkit-coreml"

    /// 官方仓库的全部档位。
    /// 注意 "turbo" 并不比压缩版更准 —— 它是「解码器砍到 4 层」的加速版，
    /// 精度低于完整 large-v3。这里如实标注，避免误导。
    static let officialModels: [WhisperModel] = [
        WhisperModel(
            repo: officialRepo,
            variant: "large-v3-v20240930_626MB",
            displayName: "Large V3 Turbo（默认）",
            subtitle: "压缩版 Turbo，626MB，多语言综合最优，中文首选",
            approximateSize: "626 MB",
            isOfficial: true
        ),
        WhisperModel(
            repo: officialRepo,
            variant: "large-v3-v20240930_turbo",
            displayName: "Large V3 Turbo（未压缩）",
            subtitle: "同为 Turbo 架构，体积更大；精度与上面接近，不必为求精度换它",
            approximateSize: "1.5 GB",
            isOfficial: true
        ),
        WhisperModel(
            repo: officialRepo,
            variant: "large-v3",
            displayName: "Large V3（完整版）",
            subtitle: "解码器 32 层，精度最高但明显更慢，适合精修场景",
            approximateSize: "约 3 GB",
            isOfficial: true
        ),
        WhisperModel(
            repo: officialRepo,
            variant: "medium",
            displayName: "Medium",
            subtitle: "中文表现不错的中间档，速度约为 large 的 3 倍",
            approximateSize: "约 1.5 GB",
            isOfficial: true
        ),
        WhisperModel(
            repo: officialRepo,
            variant: "small",
            displayName: "Small",
            subtitle: "轻量，中文可用但弱于 medium",
            approximateSize: "约 500 MB",
            isOfficial: true
        ),
        WhisperModel(
            repo: officialRepo,
            variant: "base",
            displayName: "Base",
            subtitle: "很快，中文准确率明显下降",
            approximateSize: "约 150 MB",
            isOfficial: true
        ),
        WhisperModel(
            repo: officialRepo,
            variant: "tiny",
            displayName: "Tiny",
            subtitle: "最小最快，仅建议调试用",
            approximateSize: "约 75 MB",
            isOfficial: true
        )
    ]

    /// 官方仓库中的加速变体（体积小、速度快，英文为主）
    static let distilledModels: [WhisperModel] = [
        WhisperModel(
            repo: officialRepo,
            variant: "distil*large-v3",
            displayName: "Distil Large V3",
            subtitle: "蒸馏版，英文场景快而准；中文不如 Large",
            approximateSize: "约 600 MB",
            isOfficial: true
        )
    ]

    /// 用户可选的预置合集
    static var allPresets: [WhisperModel] {
        officialModels + distilledModels
    }

    /// 默认模型：按设备内存挑选
    static var recommended: WhisperModel {
        let memoryGB = Double(ProcessInfo.processInfo.memoryGB)
        if memoryGB >= 7 {
            return officialModels[0]                       // large-v3 turbo 压缩版
        } else if memoryGB >= 5 {
            return officialModels.first { $0.variant == "medium" } ?? officialModels[0]
        } else {
            return officialModels.first { $0.variant == "small" } ?? officialModels[0]
        }
    }
}

extension ProcessInfo {
    /// 设备物理内存（GB）
    static var memoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
}

# SubWhisper

iPad 上的本地视频字幕生成工具。导入视频 → 下载 Whisper 模型 → 端上识别 → 导出 SRT/VTT 字幕。

**音频全程不离开设备**，可开飞行模式验证。

## 中文优化（重要）

很多人以为换 `turbo` 模型能提升中文准确率——**这是误解**。Turbo 的命名来自「解码器从 32 层砍到 4 层」的加速改造，它是**用精度换速度**，并不比完整版 large-v3 更准。

真正有效的手段是**提示词（initial prompt）**：

| 手段 | 效果 |
|---|---|
| 提示词加标点 | 引导模型输出带标点的文本 |
| 提示词指定"简体中文" | 强制简体，抑制繁简混杂 |
| 提示词注入专有名词 | 人名/术语准确率显著提升（社区实测 72% → 94%） |

App 里已把这三点做成 UI：**提示词风格**下拉 + **专有名词**输入框。

另外内置了 `ChineseTextNormalizer`，专门修 Whisper 的中文顽疾——它的 tokenizer 按字切分，会产出「人工智 能」这类字间空格，还会在标点前后留空格。该模块会合并字间空格、清理标点周围空格、按语境转全角标点，并过滤片尾幻觉文本。

## 换模型

WhisperKit 原生支持任意 HuggingFace 仓库：

```swift
WhisperKitConfig(model: "large-v3", modelRepo: "user/your-coreml-repo")
```

App 里提供两条路径：

1. **内置档位**：官方 large-v3 turbo / large-v3 完整版 / medium / small / base / tiny，外加 distil 蒸馏版
2. **自定义仓库**：点「添加仓库」，填 `user/repo` + 模型名（支持 `large-v3*` 通配符）

模型按仓库隔离存储在 `Documents/SubWhisperModels/<repo>__<variant>/`，避免不同仓库的同名模型互相覆盖。

> 自定义模型必须是 **WhisperKit 兼容的 CoreML 格式**（含 `.mlmodelc`）。原始 PyTorch 权重不能直接用，需先用 [whisperkittools](https://github.com/argmaxinc/whisperkittools) 转换。

## 技术栈

| 层 | 选型 |
|---|---|
| UI | SwiftUI（iOS 17+，iPad 专用） |
| 语音识别 | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)（CoreML 端上推理） |
| 音频处理 | AVFoundation（AVAssetReader 重采样至 16kHz mono WAV） |
| 工程生成 | XcodeGen（从 `project.yml` 生成 `.xcodeproj`） |
| 构建 | GitHub Actions（macOS runner，产出未签名 `.ipa`） |

## 目录结构

```
SubWhisper/
├── project.yml                  # XcodeGen 工程定义
├── Resources/
│   ├── Info.plist
│   └── Assets.xcassets/         # AppIcon 占位
├── Sources/SubWhisper/
│   ├── App/SubWhisperApp.swift  # 入口
│   ├── Models/
│   │   ├── WhisperModel.swift   # 模型描述（struct，支持任意仓库）
│   │   └── SubtitleSegment.swift# 字幕数据模型 + SRT/VTT 序列化
│   ├── Services/
│   │   ├── TranscriptionService.swift  # 下载/加载/转录主流程
│   │   └── AudioExtractor.swift        # 视频音轨抽取与重采样
│   ├── Utils/
│   │   └── ChineseTextNormalizer.swift # 中文后处理（修字间空格、标点、幻觉）
│   └── Views/
│       ├── ContentView.swift           # 主界面
│       └── ModelManagerView.swift      # 模型管理 + 自定义仓库
└── .github/workflows/build.yml  # CI 构建
```

## 在 GitHub 上构建

1. 新建一个 **公开仓库**（免费 account 只能构建公开仓库的 Actions），把本目录整个 push 上去。
2. 进入 **Actions** 标签页 → 选 `Build Unsigned IPA` → **Run workflow**。
3. 等约 10-15 分钟，在 run 页面底部 **Artifacts** 下载 `SubWhisper-unsigned-ipa`。

> 首次构建会拉取 WhisperKit 依赖并编译 CoreML 相关源码，耗时较长属正常。

## 安装到 iPad（免费 Apple ID 自签）

**你需要一台电脑（Windows 或 Mac）**，纯 iPad 无法完成签名安装。

### 方案 A：Sideloadly（推荐）

1. 电脑装 [Sideloadly](https://sideloadly.io/)，以及 iTunes（Windows 需装非 Microsoft Store 版）。
2. iPad 用数据线连电脑，解锁并点"信任此电脑"。
3. Sideloadly 选择 `SubWhisper-unsigned.ipa`，Apple ID 填你的免费账号，点 Start。
4. iPad 上 **设置 → 通用 → VPN 与设备管理** 信任你的开发者证书。
5. **设置 → 隐私与安全性 → 开发者模式** 打开并重启。

### 方案 B：AltStore

装 AltStore 后把 ipa 拖进去即可，它支持 7 天到期自动续签（需电脑端 AltServer 同网络在线）。

### 免费账号的限制

| 限制 | 说明 |
|---|---|
| 有效期 7 天 | 到期后 App 打不开，需重新签名安装 |
| 同时最多 3 个自签 App | 装新的可能要删旧的 |
| 团队 ID 限制 | 换 Apple ID 需重签 |

## 首次使用

1. 打开 App，点右上角 **模型** 图标。
2. 选 `Large V3 Turbo`（M4 iPad 推荐，626MB），点 **下载**。**必须联网**，建议 Wi-Fi。
3. 回主界面，**选择视频文件**，指定语言（或保持"自动检测"）。
4. 点 **开始识别**。
5. 完成后点 **导出 SRT**，通过分享面板存到文件 App / 发送到其他应用。

模型下载一次即可，之后完全离线可用。

## 已知限制

- **不含字幕烧录**：当前版本只导出 `.srt`/`.vtt` 字幕文件，未把字幕压进视频画面。如需烧录用剪映/CapCut 加载 srt 即可。
- **单文件串行处理**：一次处理一个文件，长视频耗时较长（M4 上 Large V3 Turbo 约 5-10 倍实时速度）。
- **Whisper 固有幻觉**：静音段偶尔会生成"谢谢观看"之类的臆测文本，导出前建议在字幕预览里检查。
- **App 图标为空**：`Assets.xcassets/AppIcon.appiconset` 只放了占位配置，需自行补一张 1024×1024 的 PNG。

## 调参位置

| 想改什么 | 改哪里 |
|---|---|
| 默认模型档位 | `WhisperModel.recommended` |
| 提示词预设 | `ChinesePromptPreset` 枚举 |
| 中文后处理规则 | `ChineseTextNormalizer` |
| 转录精度/速度权衡 | `TranscriptionService.transcribe` 里的 `DecodingOptions` |
| VAD 静音切分 | `DecodingOptions.chunkingStrategy`（当前 `.vad`） |
| 字幕合并策略 | `TranscriptionService.mergeAdjacent` |
| 支持的最小 iOS | `project.yml` 的 `deploymentTarget` |

## 许可

本项目代码可自由使用。依赖的 WhisperKit 为 MIT 协议，Whisper 模型权重来自 OpenAI（MIT）。

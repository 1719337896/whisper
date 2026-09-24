import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var service = TranscriptionService()
    @State private var selectedModelID: String = WhisperModel.recommended.id
    @State private var showImporter = false
    @State private var showModelSheet = false
    @State private var sourceFileName = ""
    @State private var sourceFileURL: URL?
    @State private var exportFormat: SubtitleFormat = .srt
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var errorMessage: String?
    @State private var languageHint: String = ""
    @State private var promptPreset: ChinesePromptPreset = .simplified
    @State private var vocabulary: String = ""
    @State private var customPrompt: String = ""
    @State private var showHistory = false
    @State private var corrections: [CorrectionRule] = HomophoneCorrector.load().map {
        CorrectionRule(wrong: $0.key, right: $0.value)
    }

    private var selectedModel: WhisperModel {
        service.allModels.first { $0.id == selectedModelID }
            ?? WhisperModel.recommended
    }

    private let languages = [
        ("", "自动检测"),
        ("zh", "中文"),
        ("en", "英语"),
        ("ja", "日语"),
        ("ko", "韩语"),
        ("es", "西班牙语"),
        ("fr", "法语"),
        ("de", "德语")
    ]

    private var importableTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie, .data, .item]
        for id in [
            "public.mp3", "com.microsoft.waveform-audio", "public.mpeg-4-audio", "public.aiff-audio",
            "public.mpeg-4", "com.apple.quicktime-movie", "public.avi", "public.mpeg",
            "org.matroska.mkv", "public.3gpp", "public.3gpp2", "com.apple.m4v-video"
        ] {
            if let t = UTType(id) { types.append(t) }
        }
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                if service.stage.isBusy { progressSection }
                modelSection
                fileSection
                chineseSection
                optionsSection
                if let warn = service.promptWarning { warningSection(warn) }
                if !service.segments.isEmpty { resultSection }
                if case .failed(let msg) = service.stage { errorSection(msg) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("SubWhisper")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHistory = true } label: {
                        Label("历史", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showModelSheet = true } label: {
                        Label("模型", systemImage: "cube.box")
                    }
                }
            }
            .background {
                DocumentPickerHost(
                    isPresented: $showImporter,
                    contentTypes: importableTypes
                ) { urls in
                    handleImport(.success(urls))
                }
            }
            .sheet(isPresented: $showModelSheet) {
                ModelManagerView(service: service, selectedModelID: $selectedModelID)
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
            .alert("出错了", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - 模型

    private var modelSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedModel.displayName)
                        .font(.headline)
                    Text(selectedModel.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectedModel.approximateSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(
                    service.isInstalled(selectedModel) ? "模型已就绪" : "模型未下载",
                    systemImage: service.isInstalled(selectedModel) ? "checkmark.circle.fill" : "arrow.down.circle"
                )
                .font(.subheadline)
                .foregroundStyle(service.isInstalled(selectedModel) ? .green : .orange)
                Spacer()
                Button("更换") { showModelSheet = true }
                    .font(.subheadline)
            }

            if !service.isInstalled(selectedModel) {
                Button {
                    Task { await service.downloadModel(selectedModel) }
                } label: {
                    Label("下载模型（\(selectedModel.approximateSize)）", systemImage: "arrow.down.to.line")
                }
                .disabled(service.stage.isBusy)
            }
        } header: {
            Text("识别模型")
        } footer: {
            if !selectedModel.isViableOnThisDevice {
                Text("当前设备内存可能不足，建议改用较小档位。")
                    .foregroundStyle(.orange)
            } else if !selectedModel.isOfficial {
                Text("自定义仓库：模型需为 WhisperKit 兼容的 CoreML 格式，否则加载会失败。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fileSection: some View {
        Section("视频 / 音频") {
            Button {
                showImporter = true
            } label: {
                Label(sourceFileName.isEmpty ? "选择视频文件" : sourceFileName, systemImage: "film.stack")
                    .lineLimit(1)
            }
            .disabled(service.stage.isBusy)

            Picker("识别语言", selection: $languageHint) {
                ForEach(languages, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }
        }
    }

    // MARK: - 中文优化

    private var chineseSection: some View {
        Section {
            Picker("提示词风格", selection: $promptPreset) {
                ForEach(ChinesePromptPreset.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("专有名词（可选）")
                    .font(.subheadline)
                TextField("人名、公司名、术语，用空格或顿号分隔", text: $vocabulary, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义提示词（可选）")
                    .font(.subheadline)
                TextField("留空则使用上面的风格。例如：这是一节物理课，请用简体中文并加标点。", text: $customPrompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }

            ForEach($corrections) { $rule in
                HStack {
                    TextField("错字", text: $rule.wrong)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("正确写法", text: $rule.right)
                }
            }
            .onDelete { offsets in
                corrections.remove(atOffsets: offsets)
                persistCorrections()
            }

            Button {
                corrections.append(CorrectionRule(wrong: "", right: ""))
            } label: {
                Label("添加同音替换", systemImage: "plus")
            }
        } header: {
            Text("中文优化")
        } footer: {
            Text("填写自定义提示词后会优先使用它，并和专有名词一起传给模型。同音替换会在识别完成后生效。")
        }
        .onChange(of: corrections) { _, _ in
            persistCorrections()
        }
    }

    private var optionsSection: some View {
        Section("导出") {
            Picker("字幕格式", selection: $exportFormat) {
                ForEach(SubtitleFormat.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.segmented)

            Button {
                startTranscription()
            } label: {
                Label("开始识别", systemImage: "waveform.badge.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sourceFileName.isEmpty || service.stage.isBusy || !service.isInstalled(selectedModel))

            if !service.segments.isEmpty {
                Button {
                    exportSubtitles()
                } label: {
                    Label("导出 \(exportFormat.rawValue)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(service.stage.description)
                    .font(.subheadline.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let fraction = service.stage.fraction {
                    ProgressView(value: fraction)
                        .animation(nil, value: fraction)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var resultSection: some View {
        Section {
            if !service.detectedLanguage.isEmpty {
                HStack {
                    Text("识别语言")
                    Spacer()
                    Text(service.detectedLanguage).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            NavigationLink {
                SubtitleListView(segments: service.segments)
            } label: {
                Label("查看字幕（\(service.segments.count) 条）", systemImage: "text.bubble")
            }
        } header: {
            Text("结果")
        }
    }

    private func errorSection(_ msg: String) -> some View {
        Section {
            Text(msg).font(.subheadline).foregroundStyle(.red)
        }
    }

    private func warningSection(_ msg: String) -> some View {
        Section {
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func persistCorrections() {
        var rules: [String: String] = [:]
        for rule in corrections where !rule.wrong.isEmpty && !rule.right.isEmpty {
            rules[rule.wrong] = rule.right
        }
        HomophoneCorrector.save(rules)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                self.sourceFileName = url.lastPathComponent
                self.sourceFileURL = dest
                service.reset()
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func startTranscription() {
        guard let url = sourceFileURL else { return }
        let lang = languageHint.isEmpty ? nil : languageHint
        Task {
            await service.transcribe(
                fileURL: url,
                model: selectedModel,
                language: lang,
                promptPreset: promptPreset,
                customVocabulary: vocabulary,
                customPrompt: customPrompt
            )
        }
    }

    private func exportSubtitles() {
        let base = (sourceFileName as NSString).deletingPathExtension
        do {
            let url = try SubtitleExporter.writeToTemporaryFile(
                service.segments,
                format: exportFormat,
                baseName: base.isEmpty ? "subtitle" : base
            )
            shareItems = [url]
            showShare = true
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 字幕列表

struct SubtitleListView: View {
    let segments: [SubtitleSegment]
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        List(segments) { seg in
            VStack(alignment: .leading, spacing: 6) {
                Text("[\(SubtitleSegment.srtFormat(seg.start))]")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(seg.text).font(.body)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("字幕预览")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(SubtitleFormat.allCases) { f in
                        Button(f.displayName) {
                            if let url = try? SubtitleExporter.writeToTemporaryFile(segments, format: f, baseName: "subtitle") {
                                shareItems = [url]
                                showShare = true
                            }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
    }
}

// MARK: - 文件选择

private struct DocumentPickerHost: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let contentTypes: [UTType]
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
        if isPresented, controller.presentedViewController == nil {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
            picker.delegate = context.coordinator
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            controller.present(picker, animated: true)
        } else if !isPresented, controller.presentedViewController is UIDocumentPickerViewController {
            controller.dismiss(animated: true)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPickerHost
        init(_ parent: DocumentPickerHost) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - 分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct CorrectionRule: Identifiable, Hashable, Equatable {
    let id = UUID()
    var wrong: String
    var right: String
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records = TranscriptStore.loadIndex()
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView("还没有识别记录", systemImage: "clock", description: Text("识别完成后会自动保存 SRT"))
                } else {
                    List {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.headline)
                                Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(record.cueCount) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                shareItems = [TranscriptStore.fileURL(for: record)]
                                showShare = true
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { records[$0] }.forEach(TranscriptStore.delete)
                            records = TranscriptStore.loadIndex()
                        }
                    }
                }
            }
            .navigationTitle("识别历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
        }
    }
}

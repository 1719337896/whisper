import SwiftUI

/// 模型管理页：切换/下载/删除模型，并支持添加任意 HuggingFace 仓库。
struct ModelManagerView: View {
    @ObservedObject var service: TranscriptionService
    @Binding var selectedModelID: String
    @Environment(\.dismiss) private var dismiss

    @State private var downloadingModel: WhisperModel?
    @State private var pendingDelete: WhisperModel?
    @State private var showAddCustom = false

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                officialSection
                distilledSection
                customSection
                storageSection
            }
            .navigationTitle("模型管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAddCustom = true
                    } label: {
                        Label("添加仓库", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddCustom) {
                AddCustomModelView(service: service)
            }
            .alert("删除模型", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let m = pendingDelete { service.deleteModel(m) }
                    pendingDelete = nil
                }
            } message: {
                Text("将删除本地模型文件，下次使用需重新下载。")
            }
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section {
            HStack {
                Label("设备内存", systemImage: "memorychip")
                Spacer()
                Text(String(format: "%.0f GB", ProcessInfo.memoryGB))
                    .foregroundStyle(.secondary)
                    .font(.subheadline.monospacedDigit())
            }
            Text("模型在设备本地运行，音频不会上传。大模型更准但更吃内存，内存不足时系统可能中断识别。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var officialSection: some View {
        Section {
            ForEach(WhisperModel.officialModels) { model in
                modelRow(model)
            }
        } header: {
            Text("官方模型")
        } footer: {
            Text("注意：Turbo 是「解码器砍到 4 层」的加速版，速度快但精度低于完整版 Large V3。追求最准请选 Large V3。")
        }
    }

    private var distilledSection: some View {
        Section {
            ForEach(WhisperModel.distilledModels) { model in
                modelRow(model)
            }
        } header: {
            Text("蒸馏加速版")
        } footer: {
            Text("体积小、速度快，英文场景表现好，中文不如 Large 系列。")
        }
    }

    private var customSection: some View {
        Section {
            if service.customModels.isEmpty {
                Text("还没有自定义仓库。点左上角「添加仓库」填入 HuggingFace 上的 CoreML 模型仓库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.customModels) { model in
                    modelRow(model, allowRemove: true)
                }
            }
        } header: {
            Text("自定义仓库")
        } footer: {
            Text("模型必须是 WhisperKit 兼容的 CoreML 格式（含 .mlmodelc）。可用 whisperkittools 自行转换后上传。")
        }
    }

    private var storageSection: some View {
        Section("存储") {
            HStack {
                Text("已下载")
                Spacer()
                Text("\(service.installedFolders.count) 个模型")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Text(TranscriptionService.modelsRoot.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func modelRow(_ model: WhisperModel, allowRemove: Bool = false) -> some View {
        let installed = service.isInstalled(model)
        let isSelected = selectedModelID == model.id

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.headline)
                        if isSelected {
                            Text("当前")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.approximateSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !model.isViableOnThisDevice {
                Label("内存可能不足", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                if installed {
                    Button {
                        selectedModelID = model.id
                        dismiss()
                    } label: {
                        Label("使用", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        pendingDelete = model
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if allowRemove {
                        Button(role: .destructive) {
                            service.removeCustomModel(model)
                        } label: {
                            Label("移除", systemImage: "minus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if downloadingModel?.id == model.id {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if case .downloadingModel(let p, _) = service.stage {
                            ProgressView(value: p).frame(width: 110)
                        }
                    }
                } else {
                    Button {
                        downloadingModel = model
                        Task {
                            await service.downloadModel(model)
                            downloadingModel = nil
                        }
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(downloadingModel != nil)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 添加自定义仓库

struct AddCustomModelView: View {
    @ObservedObject var service: TranscriptionService
    @Environment(\.dismiss) private var dismiss

    @State private var repo = ""
    @State private var variant = ""
    @State private var displayName = ""

    private var canSubmit: Bool {
        repo.contains("/") && !variant.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("author/repo-name", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("HuggingFace 仓库")
                } footer: {
                    Text("例如 argmaxinc/whisperkit-coreml")
                }

                Section {
                    TextField("large-v3 或 large-v3*", text: $variant)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("模型名（variant）")
                } footer: {
                    Text("仓库内的模型目录关键词，支持通配符 *。WhisperKit 会按此匹配唯一的模型，匹配到多个会报错。")
                }

                Section {
                    TextField("可选，留空则自动生成", text: $displayName)
                } header: {
                    Text("显示名称")
                }

                Section {
                    Button {
                        service.addCustomModel(repo: repo, variant: variant, displayName: displayName)
                        dismiss()
                    } label: {
                        Label("添加", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                } footer: {
                    Text("添加后需手动下载。模型必须是 WhisperKit 兼容的 CoreML 格式，否则加载会失败。")
                }
            }
            .navigationTitle("添加模型仓库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

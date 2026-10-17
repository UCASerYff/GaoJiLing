import SwiftUI

struct DuplicateAnalysisView: View {
    @ObservedObject var controller: DuplicateAnalysisController
    var dataBusy: Bool
    @State private var selectedIDs = Set<String>()
    @State private var contentConfirmation = false
    @State private var trashConfirmation = false
    @State private var contentScope = ""
    @State private var pendingResultID: UUID?
    @State private var pendingIDs = Set<String>()
    @State private var pendingDescription = ""
    @State private var visibleGroups = 30
    @State private var visibleFiles: [String: Int] = [:]
    private var blocked: Bool { dataBusy || controller.isBusy }
    private var selectedFiles: [DuplicateFile] { controller.result?.groups.flatMap(\.files).filter { selectedIDs.contains($0.id) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("重复文件内容分析").font(.title2.weight(.semibold))
                    Text("在明确选择的目录内读取内容，区分完全相同副本；与仅统计占用的分析独立。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择目录…") { controller.chooseDirectory() }.disabled(blocked)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.preparedDirectory?.path ?? "尚未选择范围").font(.callout).textSelection(.enabled)
                    Text("内容仅在本机读取。权限不足、云端占位、跨卷、保护范围、文件变化和预算限制会标记未完成；不下载云文件。取消在检查点生效，不能中断尚未返回的系统调用。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("相似图片识别未启用；相似不等于内容完全相同。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("确认内容分析…") {
                            guard !blocked, let directory = controller.preparedDirectory else { return }
                            contentScope = directory.path; contentConfirmation = true
                        }.buttonStyle(.borderedProminent).disabled(blocked || controller.preparedDirectory == nil)
                    }
                }.padding(6)
            }
            HStack(alignment: .top, spacing: 9) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if controller.isBusy { Button("停止") { controller.cancel() }.disabled(dataBusy) }
            }
            if let progress = controller.progress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(phase(progress.phase)) · 已访问 \(progress.visitedEntries) 项 · 独立文件 \(progress.uniqueFiles) · 已读内容 \(bytes(progress.contentBytesRead))")
                    Text("分段摘要 \(progress.sampledFiles) · 全量摘要 \(progress.hashedFiles) · 内容核验 \(progress.verifiedFiles) · 跳过 \(progress.skippedEntries) 项")
                    if controller.isBusy, let current = progress.currentPath { Text(current).lineLimit(1).truncationMode(.middle) }
                }.font(.caption).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = controller.recoveryError {
                Label("恢复记录异常，移动与恢复均已停止：\(error)", systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let result = controller.result {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("完全相同：\(result.groups.count) 组").font(.headline)
                            Spacer()
                            Text(result.complete && !result.cancelled ? "已完成" : "部分结果，不能移动")
                                .font(.callout).foregroundStyle(result.complete && !result.cancelled ? Color.secondary : .orange)
                        }
                        Text("逻辑大小与磁盘实际分配可能不同，APFS 克隆或共享块不代表可释放空间。硬链接视为同一实物；每组至少保留一个未选择的实物，默认全部保留。系统、搞系列、业务资料、共享容器、凭据和文档均不提供移动。")
                            .font(.caption).foregroundStyle(.secondary)
                        if result.groups.isEmpty {
                            Text(result.complete ? "本轮完整范围内未发现完全相同的文件组。" : "已读取部分尚未发现完全相同的文件组；未读取区域未知。")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(result.groups.prefix(visibleGroups))) { group in
                                duplicateGroup(group)
                            }
                        }
                        if visibleGroups < result.groups.count {
                            Button("再显示 30 组（还有 \(result.groups.count - visibleGroups) 组）") { visibleGroups += 30 }.disabled(blocked)
                        }
                        if let stop = result.stopReason { Text(stop).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                        ForEach(Array(result.notes.prefix(30).enumerated()), id: \.offset) { _, note in
                            Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if result.notes.count > 30 { Text("另有 \(result.notes.count - 30) 条完整性说明，请缩小范围后重新扫描以定位。") .font(.caption).foregroundStyle(.secondary) }
                        Divider()
                        HStack {
                            Text("已选 \(selectedFiles.count) 个副本 · 逻辑大小 \(bytes(selectedFiles.reduce(0) { add($0, $1.identity.byteCount) }))")
                                .font(.callout).monospacedDigit()
                            Spacer()
                            Button("移入废纸篓…", role: .destructive) { prepareTrash(result) }
                                .disabled(blocked || !result.complete || result.cancelled || selectedFiles.isEmpty || controller.recoveryError != nil)
                        }
                    }.padding(6)
                }
            }
            if let report = controller.report, !report.issues.isEmpty {
                GroupBox("未完成项目") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).font(.callout).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            if !controller.history.isEmpty {
                GroupBox("重复副本恢复记录") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("仅恢复本应用回执指向的原实物，不覆盖原位置的新文件；废纸篓被清空或实物变化时无法恢复。原记录和备份会保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(controller.history) { entry in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.body.weight(.medium))
                                    Text(entry.scope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text("\(entry.itemCount) 个副本 · \(entry.pendingCount) 项待尝试恢复 · 逻辑大小 \(bytes(entry.logicalBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("恢复此批次") { controller.restore(batchID: entry.id) }
                                    .disabled(blocked || entry.pendingCount == 0 || controller.recoveryError != nil)
                            }
                        }
                    }.padding(6)
                }
            }
        }
        .onChange(of: controller.result?.id) { _, _ in selectedIDs.removeAll(); visibleGroups = 30; visibleFiles.removeAll() }
        .alert("允许读取此目录的文件内容？", isPresented: $contentConfirmation) {
            Button("取消", role: .cancel) { }
            Button("允许并开始分析") {
                guard !blocked, controller.preparedDirectory?.path == contentScope else { return }
                _ = controller.scanPreparedDirectory(contentReadConfirmed: true)
            }
        } message: {
            Text("范围：\(contentScope)\n\n将按大小筛选、分段摘要和全量摘要读取本地内容，并核对完全相同文件。仅在本机分析，所有副本默认保留；此次确认不包含文件移动。")
        }
        .alert("将明确选择的重复副本移入废纸篓？", isPresented: $trashConfirmation) {
            Button("取消", role: .cancel) { pendingIDs.removeAll() }
            Button("复核并移入废纸篓", role: .destructive) {
                guard !blocked, let id = pendingResultID, controller.result?.id == id else { return }
                controller.execute(resultID: id, selectedIDs: pendingIDs)
                pendingIDs.removeAll(); selectedIDs.removeAll()
            }
        } message: { Text(pendingDescription) }
    }
    @ViewBuilder private func duplicateGroup(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.files.count) 个实物 · 每个 \(bytes(group.byteCount))").font(.body.weight(.medium))
                Spacer()
                Text("保留 \(group.files.filter { !selectedIDs.contains($0.id) }.count) 个").font(.caption).foregroundStyle(.secondary)
            }
            Text("SHA-256  \(group.sha256)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(Array(group.files.prefix(visibleFiles[group.id] ?? 50))) { file in
                let reason = controller.selectionBlockReason(file)
                HStack(alignment: .top, spacing: 10) {
                    if reason == nil {
                        Toggle("选择副本 \(file.name)", isOn: Binding(get: { selectedIDs.contains(file.id) }, set: { checked in
                            if checked {
                                guard group.files.filter({ !selectedIDs.contains($0.id) }).count > 1 else { return }
                                selectedIDs.insert(file.id)
                            } else { selectedIDs.remove(file.id) }
                        })).labelsHidden().toggleStyle(.checkbox)
                            .disabled(blocked || (!selectedIDs.contains(file.id) && group.files.filter { !selectedIDs.contains($0.id) }.count <= 1))
                    } else { Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 16) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.path).font(.callout).textSelection(.enabled)
                        Text("逻辑 \(bytes(file.identity.byteCount)) · 分配估算 \(bytes(file.identity.allocatedBytes)) · 设备 \(file.identity.device) / inode \(file.identity.inode)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let reason { Text("保留：\(reason)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Button { controller.reveal(file.path) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("在 Finder 中显示").disabled(blocked)
                }.padding(.vertical, 3)
            }
            if (visibleFiles[group.id] ?? 50) < group.files.count {
                Button("再显示此组 50 个实物（其余默认保留）") { visibleFiles[group.id] = (visibleFiles[group.id] ?? 50) + 50 }
                    .disabled(blocked)
            }
            Divider()
        }
    }
    private func prepareTrash(_ result: DuplicateScanResult) {
        guard !blocked, !selectedFiles.isEmpty else { return }
        pendingResultID = result.id; pendingIDs = Set(selectedFiles.map(\.id))
        let paths = selectedFiles.prefix(20).map(\.path).joined(separator: "\n")
        let more = selectedFiles.count > 20 ? "\n其余 \(selectedFiles.count - 20) 项已在列表中勾选；可取消返回检查。" : ""
        pendingDescription = "范围：\(result.scope)\n\n" + paths + more +
            "\n\n仅处理明确勾选的 \(selectedFiles.count) 个副本。移动前重新读取全部字节，与未选择的保留实物核对，保存独立恢复回执。不会清空废纸篓；占用不会因此立即释放。"
        trashConfirmation = true
    }
    private func phase(_ value: DuplicateScanPhase) -> String {
        switch value { case .enumerating: return "枚举范围"; case .sampling: return "分段筛选"; case .hashing: return "全量摘要"; case .verifying: return "内容核验"; case .finished: return "扫描结束" }
    }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file) }
    private func add(_ a: UInt64, _ b: UInt64) -> UInt64 { let sum = a.addingReportingOverflow(b); return sum.overflow ? UInt64.max : sum.partialValue }
}

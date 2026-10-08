import SwiftUI

struct CleanupView: View {
    @ObservedObject var cleanup: CleanupController
    var dataBusy: Bool
    @State private var selection = Set<String>()
    @State private var expandedGroups = Set<String>()
    @State private var expandedLists = Set<String>()
    @State private var didScan = false
    @State private var showingTrashConfirmation = false
    @State private var pendingSelection = Set<String>()
    @State private var pendingSummary = ""
    @State private var showAllCleanupHistory = false

    private var blocked: Bool { dataBusy || cleanup.isBusy }
    private var selectedItems: [CleanupItem] { cleanup.items.filter { selection.contains($0.id) } }
    private var selectedBytes: Double { selectedItems.reduce(0) { $0 + Double($1.bytes) } }
    private var categories: [String] {
        Array(Set(cleanup.items.map(\.category))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var validMemory: MemorySnapshot? {
        guard let snapshot = cleanup.memorySnapshot, snapshot.total.isFinite, snapshot.total > 0 else { return nil }
        return snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let status = cleanup.status, !status.isEmpty {
                HStack(spacing: 9) {
                    if cleanup.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "info.circle").foregroundStyle(GLPalette.accent) }
                    Text(status).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(13).background(GLPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }
            fileCleanup
            cleanupHistory
            memoryCleanup
        }
        .task(id: dataBusy) {
            while !Task.isCancelled {
                if !dataBusy && !cleanup.isBusy { cleanup.refreshMemory() }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .onChange(of: cleanup.isScanning) { oldValue, newValue in
            if newValue {
                selection.removeAll()
                expandedGroups.removeAll()
                expandedLists.removeAll()
            } else if oldValue {
                didScan = true
                expandedGroups = Set(categories)
            }
        }
        .onChange(of: cleanup.items.map(\.id)) { _, ids in
            selection.formIntersection(Set(ids))
        }
        .onChange(of: cleanup.report?.removedIDs) { _, ids in
            selection.subtract(ids ?? [])
        }
        .alert("将所选项目移到废纸篓？", isPresented: $showingTrashConfirmation) {
            Button("取消", role: .cancel) { pendingSelection.removeAll() }
            Button("移到废纸篓", role: .destructive) {
                let ids = pendingSelection
                pendingSelection.removeAll()
                guard !blocked, !ids.isEmpty else { return }
                cleanup.trash(ids: ids)
            }
        } message: {
            Text(pendingSummary)
        }
    }

    private var fileCleanup: some View {
        GLCard {
            HStack(alignment: .top, spacing: 14) {
                sectionIcon("trash", color: GLPalette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("文件清理").font(.system(size: 18, weight: .semibold))
                    Text("扫描旧缓存、轮转日志与编译产物，逐项查看后再选择。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if cleanup.isScanning {
                    Button("停止扫描") { cleanup.cancel() }.buttonStyle(.bordered)
                        .disabled(dataBusy)
                } else {
                    Button { startScan() } label: {
                        Label(didScan || !cleanup.items.isEmpty ? "重新扫描" : "开始扫描", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).disabled(blocked)
                }
            }
            Text("仅检查限定目录：超过 7 天的缓存、超过 30 天的轮转日志，以及符合条件的 Xcode 编译产物。所属应用仍在运行、无法识别归属或无法读取的项目会跳过。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if cleanup.isScanning {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在查找可供预览的项目…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.vertical, 23)
            } else if cleanup.items.isEmpty {
                GLEmptyState(icon: didScan ? "doc.text.magnifyingglass" : "folder.badge.gearshape",
                             title: didScan ? "没有可选择的项目" : "先扫描，再决定清理哪些",
                             detail: didScan ? "本次扫描没有列出可清理项目；若有跳过的目录，可在扫描说明中查看。"
                                : "扫描只读取项目信息，不会移动文件。每项默认不勾选。",
                             compact: true)
            } else {
                HStack(spacing: 10) {
                    Text("\(cleanup.items.count) 项 · \(bytes(cleanup.items.reduce(0) { $0 + Double($1.bytes) }))")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Spacer(minLength: 6)
                    Button("全选") { selection = Set(cleanup.items.map(\.id)) }
                        .disabled(blocked || selection.count == cleanup.items.count)
                    Button("取消选择") { selection.removeAll() }
                        .disabled(blocked || selection.isEmpty)
                }
                .buttonStyle(.borderless).font(.system(size: 11))
                ForEach(categories, id: \.self) { category in
                    cleanupGroup(category)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选 \(selectedItems.count) 项 · \(bytes(selectedBytes))")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text("移入废纸篓后仍可恢复。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        pendingSelection = Set(selectedItems.map(\.id))
                        let paths = selectedItems.prefix(5).map(\.displayPath).joined(separator: "\n")
                        let remaining = selectedItems.count > 5 ? "\n另有 \(selectedItems.count - 5) 项，均为列表中已勾选的项目。" : ""
                        pendingSummary = "\(selectedItems.count) 项，共 \(bytes(selectedBytes))。\n\n\(paths)\(remaining)\n\n只处理这些勾选项目，不会清空废纸篓。运行状态或文件发生变化的项目会跳过。"
                        showingTrashConfirmation = true
                    } label: {
                        Label(cleanup.isCleaning ? "正在处理…" : "移到废纸篓", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent).disabled(blocked || selectedItems.isEmpty)
                }
                .padding(.top, 5)
            }

            if !cleanup.scanNotes.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(cleanup.scanNotes.enumerated()), id: \.offset) { _, note in
                            Text(note).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)
                } label: {
                    Label("扫描说明 · \(cleanup.scanNotes.count) 条", systemImage: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                }
            }

            if let report = cleanup.report { cleanupResult(report) }

            Divider().opacity(0.5)
            HStack(alignment: .center, spacing: 10) {
                Text("移入废纸篓不会立即腾出磁盘空间。\n确认不再需要后，可自行在 Finder 中清空废纸篓。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if cleanup.canRestore {
                    Button("恢复上次清理") { cleanup.restore() }
                        .buttonStyle(.bordered).disabled(blocked)
                }
                Button("打开废纸篓") { cleanup.openTrash() }
                    .buttonStyle(.bordered).disabled(cleanup.isCleaning)
            }
        }
    }

    private func cleanupGroup(_ category: String) -> some View {
        let items = cleanup.items.filter { $0.category == category }
        let visibleItems = expandedLists.contains(category) ? items : Array(items.prefix(20))
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedGroups.contains(category) },
            set: { expanded in
                if expanded { expandedGroups.insert(category) }
                else { expandedGroups.remove(category) }
            })) {
                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        cleanupRow(item)
                        if item.id != visibleItems.last?.id { Divider().opacity(0.4) }
                    }
                    if items.count > visibleItems.count {
                        Button("显示其余 \(items.count - visibleItems.count) 项") { expandedLists.insert(category) }
                            .buttonStyle(.borderless).font(.system(size: 11)).padding(.top, 10)
                    }
                }.padding(.top, 5)
            } label: {
                HStack(spacing: 8) {
                    Text(category).font(.system(size: 12, weight: .semibold))
                    Text("\(items.count) 项").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(bytes(items.reduce(0) { $0 + Double($1.bytes) }))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(12).background(GLPalette.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cleanupRow(_ item: CleanupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { selection.contains(item.id) },
                set: { selected in
                    if selected { selection.insert(item.id) }
                    else { selection.remove(item.id) }
                })) { Text(item.name) }
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("选择 \(item.name)，\(bytes(Double(item.bytes)))")
                .disabled(blocked).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2).help(item.name)
                Text(item.displayPath).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(item.displayPath)
                if let reason = item.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(bytes(Double(item.bytes))).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 74, alignment: .trailing).padding(.top, 2)
            Button { cleanup.reveal(id: item.id) } label: {
                Image(systemName: "folder").frame(width: 23, height: 23)
            }.buttonStyle(.borderless).help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示 \(item.name)").disabled(cleanup.isCleaning)
        }.padding(.vertical, 10)
    }

    private func cleanupResult(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: report.failed.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(report.failed.isEmpty ? GLPalette.accent : GLPalette.amber)
                Text("处理结果").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            if !report.removedIDs.isEmpty {
                Text("已移入废纸篓 \(report.removedIDs.count) 项 · \(bytes(Double(report.movedBytes)))")
                    .font(.system(size: 14, weight: .medium)).monospacedDigit()
            }
            Text(report.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !report.skipped.isEmpty { issueList("已跳过", issues: report.skipped, color: GLPalette.amber) }
            if !report.failed.isEmpty { issueList("未完成", issues: report.failed, color: .red) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(GLPalette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func issueList(_ title: String, issues: [CleanupIssue], color: Color) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 3) {
                        if let item = cleanup.items.first(where: { $0.id == issue.itemID }) {
                            Text(item.name).fontWeight(.medium)
                        }
                        Text(issue.message).foregroundStyle(.secondary).textSelection(.enabled)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }.font(.system(size: 11)).padding(.top, 5)
        } label: {
            Text("\(title) \(issues.count) 项").font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }
    }

    private var cleanupHistory: some View {
        let visible = showAllCleanupHistory ? cleanup.history : Array(cleanup.history.prefix(5))
        return GLCard {
            GLSectionTitle(title: "清理历史", detail: "本机记录")
            Text("恢复会尝试放回原路径；遇到已有文件、内容变化或应用仍在运行时会跳过，不会覆盖新文件。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if visible.isEmpty {
                Text("尚无清理记录。确认移入废纸篓后，可在这里查看结果与恢复。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ForEach(visible) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            if entry.date.timeIntervalSince1970 == 0 {
                                Text("旧记录（时间未知）").font(.system(size: 12, weight: .medium))
                            } else {
                                Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text("\(entry.itemCount) 项 · 已处理占用 \(bytes(Double(entry.bytes)))")
                                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            Text(entry.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(entry.restorableCount > 0 ? "待恢复 \(entry.restorableCount) 项" : "无待恢复项目")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("恢复此批") { cleanup.restore(batchID: entry.id) }
                                .buttonStyle(.bordered).disabled(blocked || entry.restorableCount == 0)
                                .accessibilityLabel(entry.date.timeIntervalSince1970 == 0
                                                    ? "恢复时间未知的旧清理记录"
                                                    : "恢复 \(entry.date.formatted(date: .numeric, time: .shortened)) 的清理记录")
                        }
                    }.padding(.vertical, 5)
                    if entry.id != visible.last?.id { Divider().opacity(0.4) }
                }
                if cleanup.history.count > visible.count {
                    Button("显示全部 \(cleanup.history.count) 条记录") { showAllCleanupHistory = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                Text("处理占用是当时的文件大小记录，不代表已释放磁盘空间。手动清空废纸篓后，相关文件可能无法恢复。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var memoryCleanup: some View {
        GLCard {
            HStack(alignment: .top, spacing: 14) {
                sectionIcon("memorychip", color: GLPalette.blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text("释放内存").font(.system(size: 18, weight: .semibold))
                    Text("先看内存压力，再决定是否回收。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { cleanup.refreshMemory() } label: { Label("刷新读数", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).disabled(blocked)
            }
            if let snapshot = validMemory {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bytes(snapshot.used)).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("/ \(bytes(snapshot.total)) 已用").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    GLPill(text: "压力 · \(snapshot.pressure)", color: GLPalette.pressure(snapshot.pressure))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                    memoryValue("空闲内存", value: snapshot.free)
                    memoryValue("文件缓存", value: snapshot.fileCache)
                    memoryValue("可清除内存", value: snapshot.purgeable)
                    memoryValue("压缩内存", value: snapshot.compressed)
                    memoryValue("已用 Swap", value: snapshot.swap)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("读取时间").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(snapshot.date, style: .time).font(.system(size: 12, design: .monospaced))
                    }
                }.padding(.vertical, 3)
            } else {
                GLEmptyState(icon: "memorychip", title: "尚无有效内存读数",
                             detail: "点击“刷新读数”读取当前状态。读取失败时不会执行回收。",
                             compact: true)
            }
            Text("文件缓存有助于加快重复访问，压力正常时无需频繁回收。回收不会关闭其他应用，也不会通过大量分配内存施加压力；不保证减少 Swap 或改善性能。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Button { cleanup.releaseOwnMemory() } label: {
                        Label("回收本应用", systemImage: "arrow.triangle.2.circlepath")
                    }.buttonStyle(.bordered).disabled(blocked || validMemory == nil)
                    Text("回收搞机灵可归还的内存，无需管理员权限。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Button { cleanup.reclaimSystemFileCache() } label: {
                        Label("回收系统文件缓存…", systemImage: "externaldrive")
                    }.buttonStyle(.bordered).disabled(blocked || validMemory == nil)
                    Text("需在系统提示中授权管理员权限，可在授权窗口取消。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if cleanup.isReleasingMemory {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在回收并重新读取内存状态…").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }
            if let report = cleanup.memoryReport { memoryResult(report) }
        }
    }

    private func memoryResult(_ report: MemoryReleaseReport) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(report.succeeded ? "内存回收结果" : "内存回收未完成",
                  systemImage: report.succeeded ? "checkmark.circle" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(report.succeeded ? GLPalette.accent : GLPalette.amber)
            Text(report.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let released = report.releasedOwnBytes {
                Text("本应用回收 \(bytes(Double(released)))").font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                GridRow {
                    Text("读数对比")
                    Text("操作前").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("操作后").frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                comparisonRow("内存压力", before: report.before?.pressure, after: report.after?.pressure)
                comparisonRow("已用内存", before: report.before.map { bytes($0.used) }, after: report.after.map { bytes($0.used) })
                comparisonRow("空闲内存", before: report.before.map { bytes($0.free) }, after: report.after.map { bytes($0.free) })
                comparisonRow("文件缓存", before: report.before.map { bytes($0.fileCache) }, after: report.after.map { bytes($0.fileCache) })
                comparisonRow("压缩内存", before: report.before.map { bytes($0.compressed) }, after: report.after.map { bytes($0.compressed) })
                comparisonRow("已用 Swap", before: report.before.map { bytes($0.swap) }, after: report.after.map { bytes($0.swap) })
            }
            Text("读数会随系统和其他应用的活动变化，前后差值不等于本次回收量。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(GLPalette.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func comparisonRow(_ label: String, before: String?, after: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(before ?? "未读取").frame(maxWidth: .infinity, alignment: .trailing)
            Text(after ?? "未读取").frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 11)).monospacedDigit()
    }

    private func memoryValue(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(bytes(value)).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private func sectionIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name).font(.system(size: 20, weight: .regular)).foregroundStyle(color)
            .frame(width: 40, height: 40).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }

    private func bytes(_ value: Double) -> String {
        value.isFinite && value >= 0 ? Format.bytes(value) : "未知"
    }

    private func startScan() {
        guard !blocked else { return }
        didScan = true
        selection.removeAll()
        expandedGroups.removeAll()
        expandedLists.removeAll()
        cleanup.scan()
    }
}

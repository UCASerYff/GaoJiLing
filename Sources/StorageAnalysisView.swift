import SwiftUI
import Charts

struct StorageAnalysisView: View {
    @ObservedObject var analysis: StorageAnalysisController
    var dataBusy: Bool
    @State private var search = ""
    @State private var risk = ""
    @State private var sort = "size"
    @State private var expandedGroups = Set<String>()
    @State private var expandedLists = Set<String>()
    @State private var showAllLargest = false
    @State private var historyScope = ""
    @State private var showAllHistory = false

    private var blocked: Bool { dataBusy || analysis.isBusy }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var allEntries: [StorageEntry] { (analysis.result?.entries ?? []) + (analysis.result?.largestFiles ?? []) }
    private var risks: [String] {
        Array(Set(allEntries.map(\.risk).filter { !$0.isEmpty })).sorted()
    }
    private var filteredEntries: [StorageEntry] { filtered(analysis.result?.entries ?? []) }
    private var filteredLargest: [StorageEntry] { filtered(analysis.result?.largestFiles ?? []) }
    private var categories: [String] { Array(Set(filteredEntries.map(\.category))).sorted() }
    private var historyScopes: [String] { Array(Set(analysis.history.map(\.scope))).sorted() }
    private var activeHistoryScope: String {
        historyScopes.contains(historyScope) ? historyScope : (analysis.history.last?.scope ?? "")
    }
    private var scopedHistory: [StorageScanSnapshot] {
        analysis.history.filter { $0.scope == activeHistoryScope }.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let status = analysis.status, !status.isEmpty {
                HStack(spacing: 9) {
                    if analysis.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "info.circle").foregroundStyle(GLPalette.blue) }
                    Text(status).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(13).background(GLPalette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
            }
            capacityAndActions
            if let result = analysis.result {
                analysisResults(result)
                if !result.largestFiles.isEmpty { largestItems }
            } else if !analysis.isBusy {
                GLCard {
                    GLEmptyState(icon: "internaldrive", title: "先选择分析范围",
                                 detail: "可分析常见开发工具，或手动选择一个目录。\n不会自动扫描整个个人目录，也不会移动或删除文件。")
                }
            }
            exclusions
            scanHistory
        }
        .task {
            if !blocked { analysis.refreshCapacity() }
        }
        .onChange(of: analysis.result?.date) { _, date in
            expandedLists.removeAll()
            showAllLargest = false
            if date != nil {
                if !risk.isEmpty && !risks.contains(risk) { risk = "" }
                expandedGroups = Set(categories)
            }
        }
    }

    private var capacityAndActions: some View {
        GLCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "internaldrive").font(.system(size: 22))
                    .foregroundStyle(GLPalette.blue).frame(width: 42, height: 42)
                    .background(GLPalette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("磁盘空间").font(.system(size: 18, weight: .semibold))
                    Text("个人目录所在磁盘").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { analysis.refreshCapacity() } label: { Label("刷新容量", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).disabled(blocked)
            }
            if let capacity = analysis.capacity, capacity.totalBytes > 0, capacity.availableBytes >= 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bytes(capacity.availableBytes)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("可用 / 共 \(bytes(capacity.totalBytes))").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: min(max(1 - Double(capacity.availableBytes) / Double(capacity.totalBytes), 0), 1))
                    .tint(GLPalette.blue).accessibilityLabel("磁盘已用空间比例")
            } else {
                Text("磁盘容量暂不可用").font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 5)
            }
            Divider().opacity(0.5).padding(.vertical, 3)
            HStack(spacing: 10) {
                Button { analysis.scanEnvironments() } label: {
                    Label("分析开发环境", systemImage: "hammer")
                }.buttonStyle(.borderedProminent).disabled(blocked)
                Button { analysis.chooseDirectory() } label: {
                    Label("选择目录…", systemImage: "folder")
                }.buttonStyle(.bordered).disabled(blocked)
                if analysis.isBusy {
                    Button("停止分析") { analysis.cancel() }.buttonStyle(.bordered).disabled(dataBusy)
                }
                Spacer(minLength: 4)
                Button { analysis.exportReport() } label: {
                    Label("导出报告", systemImage: "square.and.arrow.up")
                }.buttonStyle(.bordered).disabled(blocked || !analysis.canExport)
                    .help("导出本次分析的全部结果与说明，不受当前搜索或筛选影响；报告包含本机路径。")
            }
            Text("只统计本地文件的名称、路径与占用，不读取文件内容或上传数据。分析结果供查看，处理建议不等于删除许可。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func analysisResults(_ result: StorageAnalysisResult) -> some View {
        GLCard {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(result.root == nil ? "开发环境占用" : "目录占用").font(.system(size: 16, weight: .semibold))
                    Text(result.root ?? "常见开发工具与本地环境")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .truncationMode(.middle).textSelection(.enabled).help(result.root ?? "开发环境")
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(bytes(result.totalBytes)).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                    GLPill(text: result.complete ? "已读取占用" : "仅已读取部分",
                           color: result.complete ? GLPalette.blue : GLPalette.amber)
                }
            }
            if !result.complete {
                Label("分析尚未完整完成，当前数值不是整个范围的总占用。请查看下方扫描说明。", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(GLPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("本地已分配空间估算，不代表可清理空间。")
                Spacer(minLength: 8)
                Text(result.date, format: .dateTime.month().day().hour().minute())
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text("APFS 共享或克隆文件可能使汇总与磁盘总占用不同。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            filterControls
            if filteredEntries.isEmpty {
                GLEmptyState(icon: "magnifyingglass",
                             title: result.entries.isEmpty ? (result.root == nil ? "没有可列出的开发环境" : "没有可列出的子目录") : "没有符合筛选条件的项目",
                             detail: result.entries.isEmpty ? (result.largestFiles.isEmpty ? "可查看扫描说明，或选择其他目录。" : "文件占用见下方“大型文件”。")
                                : "试试其他名称、路径或处理建议。",
                             compact: true)
            } else {
                Text("显示 \(filteredEntries.count) / \(result.entries.count) 项")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(categories, id: \.self) { category in
                    entryGroup(category)
                }
            }
            if !result.notes.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)
                } label: {
                    Label("扫描说明 · \(result.notes.count) 条", systemImage: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
    }

    private var filterControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索名称、路径或分类", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索存储分析结果")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除存储搜索")
                }
            }.padding(9).background(GLPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: 170)
            Picker("处理建议", selection: $risk) {
                Text("全部建议").tag("")
                ForEach(risks, id: \.self) { value in Text(value).tag(value) }
            }.labelsHidden().frame(width: 140).accessibilityLabel("按处理建议筛选")
            Picker("排序", selection: $sort) {
                Text("占用从大到小").tag("size")
                Text("名称顺序").tag("name")
                Text("文件数从多到少").tag("files")
            }.labelsHidden().frame(width: 145).accessibilityLabel("存储项目排序")
        }.font(.system(size: 11)).padding(.top, 4)
    }

    private func entryGroup(_ category: String) -> some View {
        let entries = filteredEntries.filter { $0.category == category }
        let visible = expandedLists.contains(category) ? entries : Array(entries.prefix(10))
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedGroups.contains(category) },
            set: { value in
                if value { expandedGroups.insert(category) }
                else { expandedGroups.remove(category) }
            })) {
                LazyVStack(spacing: 0) {
                    ForEach(visible, id: \.id) { entry in
                        entryRow(entry)
                        if entry.id != visible.last?.id { Divider().opacity(0.4) }
                    }
                    if entries.count > visible.count {
                        Button("显示其余 \(entries.count - visible.count) 项") { expandedLists.insert(category) }
                            .buttonStyle(.borderless).font(.system(size: 11)).padding(.top, 9)
                    }
                }.padding(.top, 6)
            } label: {
                HStack {
                    Text(category).font(.system(size: 12, weight: .semibold))
                    Text("\(entries.count) 项").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(Format.bytes(entries.reduce(0.0) { $0 + Double($1.bytes) }))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(12).background(GLPalette.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    private func entryRow(_ entry: StorageEntry) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(2).help(entry.name)
                Text(entry.path).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(entry.path)
                if !entry.reason.isEmpty {
                    Text(entry.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text(bytes(entry.bytes)).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("\(entry.fileCount) 个文件").font(.system(size: 10)).foregroundStyle(.secondary)
                GLPill(text: entry.risk.isEmpty ? "未分类" : entry.risk, color: riskColor(entry.risk))
            }.frame(minWidth: 100, alignment: .trailing)
            Button { analysis.reveal(entry) } label: { Image(systemName: "folder").frame(width: 23, height: 23) }
                .buttonStyle(.borderless).help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示 \(entry.name)")
        }.padding(.vertical, 11)
    }

    private var largestItems: some View {
        let visible = showAllLargest ? filteredLargest : Array(filteredLargest.prefix(10))
        return GLCard {
            GLSectionTitle(title: "大型文件", detail: "同样应用上方搜索与筛选")
            Text("这些文件可能已包含在上方目录汇总中，请勿累加。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if visible.isEmpty {
                Text("没有符合筛选条件的大型文件。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible, id: \.id) { entry in
                        entryRow(entry)
                        if entry.id != visible.last?.id { Divider().opacity(0.4) }
                    }
                }
                if filteredLargest.count > visible.count {
                    Button("显示其余 \(filteredLargest.count - visible.count) 项") { showAllLargest = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
        }
    }

    private var exclusions: some View {
        GLCard {
            HStack {
                GLSectionTitle(title: "排除目录")
                Spacer(minLength: 8)
                Button { analysis.addExclusion() } label: { Label("添加目录…", systemImage: "plus") }
                    .buttonStyle(.bordered).disabled(blocked)
            }
            Text("跳过所选目录及其子目录，下次分析生效。规则只影响存储分析，清理页仍使用独立的保护范围。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if analysis.exclusions.isEmpty {
                Text("尚未添加排除目录").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else {
                ForEach(analysis.exclusions, id: \.path) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.minus").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(url.path).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled).help(url.path)
                        Spacer(minLength: 5)
                        Button { analysis.removeExclusion(url) } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                            .buttonStyle(.borderless).disabled(blocked).help("移除排除规则")
                            .accessibilityLabel("移除排除目录 \(url.lastPathComponent)")
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    private var scanHistory: some View {
        let snapshots = scopedHistory
        let visible = showAllHistory ? Array(snapshots.reversed()) : Array(snapshots.reversed().prefix(5))
        return GLCard {
            HStack {
                GLSectionTitle(title: "占用记录", detail: "本机最近 30 次扫描")
                if !historyScopes.isEmpty {
                    Picker("扫描范围", selection: Binding(get: { activeHistoryScope }, set: { historyScope = $0; showAllHistory = false })) {
                        ForEach(historyScopes, id: \.self) { scope in Text(scope).tag(scope) }
                    }.labelsHidden().frame(maxWidth: 290).accessibilityLabel("占用记录的扫描范围")
                }
            }
            if snapshots.isEmpty {
                Text("完成分析后，在这里查看本机占用记录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                Text(activeHistoryScope).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(activeHistoryScope)
                if snapshots.filter(\.complete).count > 1 {
                    StorageHistoryChart(snapshots: snapshots.filter(\.complete))
                }
                ForEach(visible) { snapshot in
                    HStack(spacing: 12) {
                        Text(snapshot.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if !snapshot.complete { GLPill(text: "部分", color: GLPalette.amber) }
                        Text(bytes(snapshot.totalBytes)).font(.system(size: 12, design: .monospaced))
                    }.accessibilityElement(children: .combine)
                }
                if snapshots.count > visible.count {
                    Button("显示全部 \(snapshots.count) 次记录") { showAllHistory = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                Text("趋势仅绘制同一扫描范围的完整记录；未完成的扫描只列出已读取部分。排除规则变化也会影响结果。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func filtered(_ entries: [StorageEntry]) -> [StorageEntry] {
        entries.filter { entry in
            (risk.isEmpty || entry.risk == risk) &&
            (query.isEmpty || [entry.name, entry.path, entry.category, entry.risk, entry.reason]
                .contains { $0.localizedStandardContains(query) })
        }.sorted { first, second in
            if sort == "name" { return first.name.localizedStandardCompare(second.name) == .orderedAscending }
            if sort == "files", first.fileCount != second.fileCount { return first.fileCount > second.fileCount }
            if first.bytes != second.bytes { return first.bytes > second.bytes }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    private func riskColor(_ value: String) -> Color {
        if ["谨慎", "重要", "勿", "风险", "需确认"].contains(where: value.contains) { return GLPalette.amber }
        return GLPalette.blue
    }

    private func bytes(_ value: Int64) -> String { value >= 0 ? Format.bytes(Double(value)) : "未知" }
}

private struct StorageHistoryChart: View {
    let snapshots: [StorageScanSnapshot]
    var body: some View {
        Chart(snapshots) { snapshot in
            BarMark(x: .value("扫描时间", snapshot.date), y: .value("已分配空间", Double(snapshot.totalBytes)))
                .foregroundStyle(GLPalette.blue.opacity(0.65))
                .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.055))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(Format.bytes(bytes)).font(.system(size: 9)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel(format: .dateTime.month().day().hour().minute()).font(.system(size: 9))
            }
        }
        .frame(height: 130)
        .accessibilityLabel("同一扫描范围的完整占用记录，不包含部分扫描")
    }
}

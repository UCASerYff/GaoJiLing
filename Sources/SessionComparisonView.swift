import Charts
import SwiftUI

@MainActor
struct GLCompletedSessions: View {
    @ObservedObject var store: MonitorStore
    @State private var selection: [UUID] = []
    @State private var comparison: GLSessionComparison?
    @State private var errorMessage: String?

    private var completed: [MonitorSession] {
        store.sessions.filter { $0.end != nil }.sorted { $0.start > $1.start }
    }

    var body: some View {
        let sessions = completed
        VStack(alignment: .leading, spacing: 14) {
            if sessions.count >= 2 {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已完成的任务").font(.system(size: 13, weight: .semibold))
                        Text("按选取顺序设为 A、B").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text("已选 \(selection.count)/2").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if !selection.isEmpty { Button("清空选择", action: clearSelection) }
                    Button("比较所选任务", action: openComparison)
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.count != 2)
                        .accessibilityIdentifier("session-comparison.open")
                }
            } else {
                GLSectionTitle(title: "已完成的任务", detail: "保存两条记录后可对比")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(GLPalette.amber)
                    .accessibilityLabel("无法比较任务。\(errorMessage)")
            }
            if sessions.isEmpty {
                GLCard {
                    GLEmptyState(icon: "tray", title: "第一份记录，从下一项工作开始", detail: "结束任务后，可以在这里查看汇总并导出。")
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(sessions) { session in
                        sessionRow(session, canSelect: sessions.count >= 2)
                    }
                }
            }
        }
        .onChange(of: sessions.map(\.id)) { _, available in
            let ids = Set(available)
            if available.count < 2 {
                clearSelection()
            } else if selection.contains(where: { !ids.contains($0) }) {
                selection.removeAll(where: { !ids.contains($0) })
                comparison = nil
                errorMessage = "所选任务已变化，请重新选择。"
            }
        }
        .sheet(item: $comparison) { result in
            GLSessionComparisonView(result: result)
        }
    }

    private func sessionRow(_ session: MonitorSession, canSelect: Bool) -> some View {
        let position = selection.firstIndex(of: session.id)
        let date = session.start.formatted(date: .abbreviated, time: .standard)
        return GLCard {
            HStack(spacing: 12) {
                if canSelect {
                    Toggle("选取任务 \(session.name)", isOn: Binding(
                        get: { selection.contains(session.id) },
                        set: { selected in updateSelection(session.id, selected: selected) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("选取任务 \(session.name)")
                    .accessibilityHint(position.map { "\(GLSessionComparison.slot($0)) 项，开始于 \(date)" } ?? "开始于 \(date)")
                    .accessibilityIdentifier("session-comparison.select.\(session.id.uuidString)")
                    .disabled(position == nil && selection.count == 2)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).help(session.name)
                    Text(date).font(.system(size: 10)).foregroundStyle(.secondary)
                    if session.interrupted == true {
                        Label("上次运行中断，已恢复至最后采样", systemImage: "arrow.clockwise.circle")
                            .font(.system(size: 10)).foregroundStyle(GLPalette.amber)
                    }
                }
                if let position {
                    GLPill(text: GLSessionComparison.slot(position), color: GLSessionComparison.color(position))
                }
                Spacer(minLength: 8)
                Text(Format.duration(session.duration)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                if position == 1 {
                    Button("比较", action: openComparison)
                        .help("比较两条选中的任务")
                        .accessibilityLabel("比较所选任务")
                }
                Button { store.exportSession(session) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).help("导出任务记录").accessibilityLabel("导出任务：\(session.name)")
            }
            Divider().opacity(0.5).padding(.vertical, 3)
            HStack {
                GLSensor(label: "CPU 峰值", value: session.sampleCount > 0 ? Format.percent(session.peakCPU) : nil, fallback: "没有采样")
                GLSensor(label: "CPU 平均", value: session.sampleCount > 0 ? Format.percent(session.averageCPU) : nil, fallback: "没有采样")
                GLSensor(label: "内存峰值", value: session.peakMemory > 0 ? Format.bytes(session.peakMemory) : nil, fallback: "没有采样")
                GLSensor(label: "温度峰值", value: session.peakTemperature.map { String(format: "%.0f °C", $0) }, fallback: "未读取传感器")
            }
        }
    }

    private func updateSelection(_ id: UUID, selected: Bool) {
        if selected {
            guard selection.count < 2, !selection.contains(id) else { return }
            selection.append(id)
        } else {
            selection.removeAll { $0 == id }
        }
        errorMessage = nil
    }

    private func clearSelection() {
        selection.removeAll()
        comparison = nil
        errorMessage = nil
    }

    private func openComparison() {
        guard selection.count == 2 else { return }
        do {
            let runs = try store.compareSessions(selection)
            guard runs.count == 2, runs.map(\.session.id) == selection else {
                errorMessage = "所选任务已变化，请重新选择。"
                return
            }
            errorMessage = nil
            comparison = GLSessionComparison(first: runs[0], second: runs[1])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GLSessionComparison: Identifiable {
    let id = UUID()
    let first: SessionComparisonRun
    let second: SessionComparisonRun

    var elapsedMaximum: Double {
        max(1, first.duration, second.duration, first.trend.last?.elapsed ?? 0, second.trend.last?.elapsed ?? 0)
    }

    var memoryMaximum: Double {
        max(1, first.trend.compactMap(\.memory).max() ?? 0, second.trend.compactMap(\.memory).max() ?? 0)
    }

    static func slot(_ index: Int) -> String { index == 0 ? "A" : "B" }
    static func color(_ index: Int) -> Color { index == 0 ? GLPalette.accent : GLPalette.blue }
}

private struct GLSessionComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    let result: GLSessionComparison

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务对比结果").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    GLCard {
                        GLSectionTitle(title: "会话采样趋势", detail: "共用刻度")
                        Text("横轴从各任务开始计时。缺少连续采样的区间留白。")
                            .font(.caption).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                trend(result.first, index: 0).frame(minWidth: 290)
                                trend(result.second, index: 1).frame(minWidth: 290)
                            }
                            VStack(spacing: 12) {
                                trend(result.first, index: 0)
                                trend(result.second, index: 1)
                            }
                        }
                    }
                    GLCard {
                        GLSectionTitle(title: "进程占用排行", detail: "会话内采样")
                        Text("每次任务取有有效进程读数的最高整机 CPU 采样，按进程组的整机 CPU 占比排序。内存为当时的物理内存用量（physical footprint）。")
                            .font(.caption).foregroundStyle(.secondary)
                        if result.first.processSnapshot == nil || result.second.processSnapshot == nil {
                            Text("至少一条任务缺少可归属的快照，两次排行不可比较。")
                                .font(.caption).foregroundStyle(GLPalette.amber)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                rankings(result.first, index: 0).frame(minWidth: 290)
                                rankings(result.second, index: 1).frame(minWidth: 290)
                            }
                            VStack(spacing: 12) {
                                rankings(result.first, index: 0)
                                rankings(result.second, index: 1)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GLPalette.canvas)
        }
        .frame(minWidth: 625, idealWidth: 780, minHeight: 480, idealHeight: 690)
    }

    private var summary: some View {
        GLCard {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow(alignment: .top) {
                    Text("指标").foregroundStyle(.secondary).frame(minWidth: 72, alignment: .leading)
                    summaryHeading(result.first, index: 0)
                    summaryHeading(result.second, index: 1)
                    Text("差值 B−A").foregroundStyle(.secondary).frame(minWidth: 86, alignment: .leading)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(GLSessionComparisonMetric.allCases, id: \.self) { metric in
                    GridRow {
                        Text(metric.title).fontWeight(.medium)
                        metricReading(metric.reading(in: result.first), missing: "未采样")
                        metricReading(metric.reading(in: result.second), missing: "未采样")
                        metricReading(metric.difference(in: result), missing: "不可比较")
                    }
                }
            }
            .font(.callout)
            Text("耗时按时:分:秒显示。CPU 为全机占用，差值用百分点。内存使用二进制单位。")
                .font(.caption).foregroundStyle(.secondary)
            if result.first.session.interrupted == true || result.second.session.interrupted == true {
                Text("中断任务只显示已记录的时长，耗时差值不可比较。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metricReading(_ value: String?, missing: String) -> some View {
        Text(value ?? missing).monospacedDigit().foregroundStyle(value == nil ? Color.secondary : Color.primary)
    }

    private func summaryHeading(_ run: SessionComparisonRun, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            runTitle(run, index: index)
            if let end = run.session.end {
                Text(dateRange(run.session.start, end)).font(.caption).foregroundStyle(.secondary)
            }
            if run.session.interrupted == true {
                GLPill(text: "中断记录", color: GLPalette.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trend(_ run: SessionComparisonRun, index: Int) -> some View {
        let unit = GLSessionMemoryUnit.covering(result.memoryMaximum)
        return detailPanel(run, index: index) {
            if let start = run.sampleStart, let end = run.sampleEnd {
                Text("采样 \(dateRange(start, end))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("没有可用的采样时间范围").font(.caption).foregroundStyle(.secondary)
            }
            if let count = run.sampleCount {
                Text("系统采样 \(count) 次 · CPU \(run.session.sampleCount) 次")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("总采样次数未知 · CPU \(run.session.sampleCount) 次")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if run.trend.isEmpty {
                Text("此任务没有可绘制的采样点。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(trendSource(run.trendSource)) · 显示 \(run.trend.count) 个采样点")
                    .font(.caption).foregroundStyle(.secondary)
                GLSessionTrendChart(title: "CPU 占用", unit: "%", color: GLPalette.accent, elapsedMaximum: result.elapsedMaximum,
                                    maximum: 100, points: GLSessionTrendPoint.values(run, read: { $0.cpu }))
                GLSessionTrendChart(title: "已用内存", unit: unit.label, color: GLPalette.blue, elapsedMaximum: result.elapsedMaximum,
                                    maximum: result.memoryMaximum / unit.divisor,
                                    points: GLSessionTrendPoint.values(run, read: { $0.memory.map { $0 / unit.divisor } }))
            }
        }
    }

    private func rankings(_ run: SessionComparisonRun, index: Int) -> some View {
        detailPanel(run, index: index) {
            if let snapshot = run.processSnapshot, !snapshot.rows.isEmpty {
                Text("采样于 \(snapshot.timestamp.formatted(date: .abbreviated, time: .standard)) · 整机 CPU \(GLSessionComparisonMetric.percent(snapshot.systemCPU))")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("进程组").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").gridColumnAlignment(.trailing)
                        Text("内存").gridColumnAlignment(.trailing)
                    }
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(snapshot.rows.indices, id: \.self) { index in
                        let process = snapshot.rows[index]
                        GridRow {
                            Text("\(index + 1). \(process.name)").lineLimit(2).help(process.name)
                            Text(GLSessionComparisonMetric.percent(process.cpu)).monospacedDigit()
                            metricReading(process.memory.map(GLSessionMemoryUnit.formatted), missing: "未采样")
                        }
                    }
                }
                .font(.caption)
            } else {
                Text("这条任务没有可归属的进程快照。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detailPanel<Content: View>(_ run: SessionComparisonRun, index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            runTitle(run, index: index)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GLPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
    }

    private func runTitle(_ run: SessionComparisonRun, index: Int) -> some View {
        HStack(spacing: 6) {
            GLPill(text: GLSessionComparison.slot(index), color: GLSessionComparison.color(index))
            Text(run.session.name).font(.callout.weight(.semibold)).lineLimit(2).help(run.session.name)
        }
    }

    private func trendSource(_ source: SessionComparisonTrendSource) -> String {
        switch source {
        case .session: return "来自任务采样"
        case .history: return "来自任务时段内仍保留的系统历史"
        }
    }

    private func dateRange(_ start: Date, _ end: Date) -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) {
            let day = start.formatted(date: .abbreviated, time: .omitted)
            return "\(day) \(start.formatted(date: .omitted, time: .standard))–\(end.formatted(date: .omitted, time: .standard))"
        }
        return "\(start.formatted(date: .abbreviated, time: .standard)) 至 \(end.formatted(date: .abbreviated, time: .standard))"
    }
}

private enum GLSessionComparisonMetric: CaseIterable, Hashable {
    case duration, meanCPU, peakCPU, memory

    var title: String {
        switch self {
        case .duration: return "耗时"
        case .meanCPU: return "CPU 均值"
        case .peakCPU: return "CPU 峰值"
        case .memory: return "内存峰值"
        }
    }

    private func rawValue(in run: SessionComparisonRun) -> Double? {
        switch self {
        case .duration: return run.duration
        case .meanCPU: return run.averageCPU
        case .peakCPU: return run.peakCPU
        case .memory: return run.peakMemory
        }
    }

    func reading(in run: SessionComparisonRun) -> String? {
        rawValue(in: run).map { value in
            switch self {
            case .duration: return Self.elapsed(value)
            case .meanCPU, .peakCPU: return Self.percent(value)
            case .memory: return GLSessionMemoryUnit.formatted(value)
            }
        }
    }

    func difference(in result: GLSessionComparison) -> String? {
        if self == .duration && (result.first.session.interrupted == true || result.second.session.interrupted == true) { return nil }
        guard let first = rawValue(in: result.first), let second = rawValue(in: result.second) else { return nil }
        let precision = (self == .meanCPU || self == .peakCPU) ? 10.0 : 1.0
        let delta = ((second - first) * precision).rounded() / precision
        let sign = delta < 0 ? "−" : delta > 0 ? "+" : ""
        switch self {
        case .duration: return sign + Self.elapsed(abs(delta))
        case .meanCPU, .peakCPU: return sign + Self.decimal(abs(delta)) + " 个百分点"
        case .memory: return sign + GLSessionMemoryUnit.formatted(abs(delta))
        }
    }

    static func elapsed(_ elapsed: Double) -> String {
        let seconds = Int(max(0, elapsed).rounded())
        return [seconds / 3600, seconds / 60 % 60, seconds % 60]
            .map { $0 < 10 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    static func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    static func percent(_ value: Double) -> String { decimal(value) + "%" }
}

private enum GLSessionMemoryUnit: Int, CaseIterable {
    case byte, kibibyte, mebibyte, gibibyte, tebibyte, pebibyte

    var label: String { ["B", "KiB", "MiB", "GiB", "TiB", "PiB"][rawValue] }
    var divisor: Double { pow(1024, Double(rawValue)) }

    static func covering(_ bytes: Double) -> Self { allCases.last(where: { bytes >= $0.divisor }) ?? .byte }

    static func formatted(_ bytes: Double) -> String {
        let unit = covering(bytes)
        return GLSessionComparisonMetric.decimal(bytes / unit.divisor) + " " + unit.label
    }
}

private struct GLSessionTrendPoint: Identifiable {
    let id: Int
    let elapsed: Double
    let value: Double
    let segment: Int

    static func values(_ run: SessionComparisonRun, read: (SessionComparisonPoint) -> Double?) -> [Self] {
        var previous: Double?
        var segment = 0
        var output: [Self] = []
        for (index, point) in run.trend.enumerated() {
            guard let value = read(point) else {
                if previous != nil { segment += 1 }
                previous = nil
                continue
            }
            if let previous, point.elapsed - previous > run.trendGap { segment += 1 }
            output.append(Self(id: index, elapsed: point.elapsed, value: value, segment: segment))
            previous = point.elapsed
        }
        return output
    }
}

private struct GLSessionTrendChart: View {
    let title: String
    let unit: String
    let color: Color
    let elapsedMaximum: Double
    let maximum: Double
    let points: [GLSessionTrendPoint]
    @State private var inspectedIndex: Int?

    private var elapsedMarks: [Double] {
        elapsedMaximum >= 2 ? [0, (elapsedMaximum / 2).rounded(.down), elapsedMaximum] : [0, elapsedMaximum]
    }

    private var inspectedPoint: GLSessionTrendPoint? {
        guard let inspectedIndex, points.indices.contains(inspectedIndex) else { return nil }
        return points[inspectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            if points.isEmpty {
                Text("没有可用读数").font(.caption).foregroundStyle(.secondary)
            } else {
                let segments = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
                Chart {
                    ForEach(points) { point in
                        if segments[point.segment] == 1 {
                            PointMark(x: .value("已用时间", point.elapsed), y: .value(title, point.value))
                                .foregroundStyle(color).symbolSize(18)
                        } else {
                            LineMark(x: .value("已用时间", point.elapsed), y: .value(title, point.value),
                                     series: .value("采样段", point.segment))
                                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round))
                        }
                    }
                    if let point = inspectedPoint {
                        RuleMark(x: .value("所选采样时间", point.elapsed)).foregroundStyle(Color.secondary)
                        PointMark(x: .value("所选采样时间", point.elapsed), y: .value(title, point.value))
                            .foregroundStyle(color).symbolSize(32)
                    }
                }
                .chartXScale(domain: 0...elapsedMaximum)
                .chartYScale(domain: 0...maximum)
                .chartXAxis {
                    AxisMarks(values: elapsedMarks) { value in
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(GLSessionComparisonMetric.elapsed(seconds)).font(.caption2).monospacedDigit()
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, maximum / 2, maximum]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let reading = value.as(Double.self) {
                                Text(GLSessionComparisonMetric.decimal(reading)).font(.caption2).monospacedDigit()
                            }
                        }
                    }
                }
                .frame(height: 106)
                .focusable()
                .onMoveCommand(perform: inspect)
                .accessibilityLabel("\(title)趋势，单位\(unit)")
                .accessibilityHint("使用左右方向键查看实际采样点")
                .accessibilityValue(Text(inspectedPoint.map(reading) ?? "共 \(points.count) 个采样点"))
                if let point = inspectedPoint {
                    Text(reading(point)).font(.caption2).monospacedDigit().accessibilityHidden(true)
                }
            }
        }
    }

    private func inspect(_ direction: MoveCommandDirection) {
        guard let last = points.indices.last else { return }
        switch direction {
        case .left: inspectedIndex = max(0, (inspectedIndex ?? last + 1) - 1)
        case .right: inspectedIndex = min(last, (inspectedIndex ?? -1) + 1)
        case .up, .down: break
        @unknown default: break
        }
    }

    private func reading(_ point: GLSessionTrendPoint) -> String {
        "\(GLSessionComparisonMetric.elapsed(point.elapsed)) · \(GLSessionComparisonMetric.decimal(point.value)) \(unit)"
    }
}

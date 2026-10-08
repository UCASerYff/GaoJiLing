import SwiftUI
import AppKit
import Charts

enum GLPalette {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let accent = adaptive(
        light: NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.43, alpha: 1),
        dark: NSColor(calibratedRed: 0.40, green: 0.76, blue: 0.67, alpha: 1))
    static let amber = adaptive(
        light: NSColor(calibratedRed: 0.77, green: 0.48, blue: 0.17, alpha: 1),
        dark: NSColor(calibratedRed: 0.94, green: 0.69, blue: 0.36, alpha: 1))
    static let blue = adaptive(
        light: NSColor(calibratedRed: 0.35, green: 0.49, blue: 0.68, alpha: 1),
        dark: NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.91, alpha: 1))
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.10, green: 0.115, blue: 0.12, alpha: 1)
            : NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.945, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.145, green: 0.16, blue: 0.165, alpha: 1)
            : NSColor(calibratedWhite: 1, alpha: 0.94)
    })
    static func pressure(_ value: String) -> Color {
        if ["严重", "危急", "紧急", "高", "critical"].contains(value) { return .red }
        if ["警告", "偏高", "紧张", "偏暖", "中", "warning", "fair"].contains(value) { return amber }
        if ["正常", "低", "normal", "nominal"].contains(value) { return accent }
        return .secondary
    }
}

enum GLPage: String, CaseIterable, Identifiable {
    case overview = "概览", apps = "应用", history = "回看", sessions = "任务", network = "网络", cleanup = "清理", storage = "存储"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .apps: return "square.stack.3d.up"
        case .history: return "clock.arrow.circlepath"
        case .sessions: return "record.circle"
        case .network: return "network"
        case .cleanup: return "sparkles"
        case .storage: return "internaldrive"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "电脑的小动静，一眼就知道。"
        case .apps: return "找到正在消耗资源的应用。"
        case .history: return "沿着时间，回看每一次状态变化。"
        case .sessions: return "为编译、渲染和每一项专注的工作留一份记录。"
        case .network: return "按需检查连接，了解网络在哪里遇到问题。"
        case .cleanup: return "先查看，再清理；按需回收内存。"
        case .storage: return "查看开发环境和所选目录的占用。"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var cleanup: CleanupController
    @ObservedObject var analysis: StorageAnalysisController
    var openSettings: () -> Void
    @State private var page: GLPage = .overview
    @State private var search = ""
    @State private var appSort = "cpu"
    @State private var historyMinutes = 60
    @State private var sessionName = ""
    @State private var diagnosticHost = "www.apple.com"
    private var hasLiveSample: Bool { store.latest.memoryTotal > 0 }
    private var searchQuery: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedTimeLabel: String { historyMinutes == 10 ? "10 分钟" : historyMinutes == 60 ? "1 小时" : "24 小时" }
    private var scrollIdentity: String {
        page.rawValue + (page == .history ? (store.focusedEvent?.id.uuidString ?? "current") : "")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            VStack(spacing: 0) {
                header
                if let message = store.statusMessage, !message.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(message).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if store.dataBusy { ProgressView().controlSize(.small) }
                        else { Button { store.statusMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭操作提示") }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(12).background(GLPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 28).padding(.bottom, 12)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .overview: overview
                        case .apps: applications
                        case .history: history
                        case .sessions: sessions
                        case .network: network
                        case .cleanup: CleanupView(cleanup: cleanup, dataBusy: store.dataBusy || analysis.isBusy)
                        case .storage: StorageAnalysisView(analysis: analysis, dataBusy: store.dataBusy || cleanup.isBusy)
                        }
                    }
                    .disabled(store.dataBusy)
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: 1200, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .id(scrollIdentity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GLPalette.canvas)
        }
        .tint(GLPalette.accent)
        .frame(minWidth: 960, minHeight: 650)
        .onChange(of: store.focusedEvent?.id) { _, newValue in
            if newValue != nil { page = .history }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("搞机灵").font(.system(size: 18, weight: .semibold)).fixedSize()
                        Text("V\(GLPalette.version)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(GLPalette.accent)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(GLPalette.accent.opacity(0.09), in: Capsule())
                            .fixedSize()
                            .accessibilityLabel("版本 \(GLPalette.version)")
                    }
                    Text("Mac 状态观察站").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 20)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 24).padding(.bottom, 12)
            ForEach(GLPage.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.icon).font(.system(size: 16)).frame(width: 20)
                        Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .regular))
                        Spacer()
                        if item == .sessions && store.activeSession != nil {
                            Circle().fill(GLPalette.accent).frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(page == item ? GLPalette.accent : Color.primary.opacity(0.75))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(page == item ? GLPalette.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 5)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(store.isPaused ? GLPalette.amber : GLPalette.accent).frame(width: 6, height: 6)
                    Text(store.isPaused ? "采样已暂停" : "在本机，安静观察").font(.system(size: 11))
                }
                Text(store.hardwareDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                Divider().padding(.vertical, 3)
                HStack {
                    Text("呼出面板")
                    Spacer()
                    Text("⌥⌘\(store.settings.hotkeyChoice.uppercased())")
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(22)
        }
        .frame(width: 198)
        .background(GLPalette.card.opacity(0.72))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(page.rawValue).font(.system(size: 27, weight: .semibold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(store.isPaused ? GLPalette.amber : GLPalette.accent).frame(width: 5, height: 5)
                        Text(store.isPaused ? "已暂停" : hasLiveSample ? "实时采样" : "准备采样").font(.system(size: 11, weight: .medium))
                    }
                    if hasLiveSample {
                        Text(store.latest.timestamp, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    } else {
                        Text("尚无有效采样").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Button { store.togglePause() } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill").frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless).help(store.isPaused ? "恢复采样" : "暂停采样")
                .accessibilityLabel(store.isPaused ? "恢复采样" : "暂停采样")
                .disabled(store.dataBusy)
            }
            Divider().frame(height: 25).padding(.horizontal, 4)
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 16))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("设置（⌘,）")
            .accessibilityLabel("打开搞机灵设置")
        }
        .padding(.horizontal, 28).padding(.top, 29).padding(.bottom, 24)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                GLMetricCard(title: "处理器", icon: "cpu", value: Format.percent(store.latest.cpuPercent), detail: store.latest.corePercents.isEmpty ? "等待 CPU 基线采样" : "\(store.latest.corePercents.count) 核心 · 全机占用", color: GLPalette.accent, values: store.history.suffix(35).compactMap(\.cpuPercent))
                GLMetricCard(title: "内存", icon: "memorychip", value: hasLiveSample ? Format.bytes(store.latest.memoryUsed) : "—", detail: hasLiveSample ? "共 \(Format.bytes(store.latest.memoryTotal)) · 压力\(store.latest.memoryPressure)" : "等待内存采样", color: GLPalette.blue, values: store.history.suffix(35).filter { $0.memoryTotal > 0 }.map(\.memoryPercent))
                GLMetricCard(title: "网络下载", icon: "arrow.down.right", value: Format.rate(store.latest.networkDown), detail: "上传 \(Format.rate(store.latest.networkUp))", color: GLPalette.amber, values: store.history.suffix(35).compactMap(\.networkDown))
            }
            GLCard {
                GLSectionTitle(title: "近期趋势", detail: "最近 \(min(store.history.count, 90)) 次采样")
                HStack(alignment: .top, spacing: 24) {
                    GLTrendChart(samples: Array(store.history.suffix(90)), metric: .cpu, title: "CPU 占用", color: GLPalette.accent, height: 136, isPaused: store.isPaused)
                    GLTrendChart(samples: Array(store.history.suffix(90)), metric: .memory, title: "内存占用", color: GLPalette.blue, height: 136, isPaused: store.isPaused)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                GLCard {
                    GLSectionTitle(title: "内存与存储", detail: "看压力，也看余量")
                    HStack {
                        Text("内存压力").foregroundStyle(.secondary)
                        Spacer()
                        GLPill(text: store.latest.memoryPressure, color: GLPalette.pressure(store.latest.memoryPressure))
                    }.font(.system(size: 12))
                    GLValueRow(label: "压缩内存", value: hasLiveSample ? Format.bytes(store.latest.memoryCompressed) : "—")
                    GLValueRow(label: "已用 Swap", value: hasLiveSample ? Format.bytes(store.latest.swapUsed) : "—")
                    Divider().opacity(0.5).padding(.vertical, 2)
                    GLValueRow(label: "启动盘可用", value: store.latest.diskTotal > 0 ? Format.bytes(store.latest.diskFree) : "—")
                    if store.latest.diskTotal > 0 {
                        ProgressView(value: min(max(1 - store.latest.diskFree / store.latest.diskTotal, 0), 1))
                            .tint(GLPalette.blue)
                            .accessibilityLabel("启动盘已用空间比例")
                    }
                    GLValueRow(label: "磁盘读 / 写", value: "\(Format.rate(store.latest.diskRead)) / \(Format.rate(store.latest.diskWrite))")
                }
                GLCard {
                    GLSectionTitle(title: "活跃应用", detail: "CPU · 全机口径")
                    if store.latest.processes.isEmpty {
                        GLEmptyState(icon: store.isPaused ? "pause.circle" : "square.stack.3d.up", title: store.isPaused ? "采样已暂停" : "正在获取应用", detail: store.isPaused ? "恢复采样后显示应用资源排行。" : "资源排行将在采样完成后显示。", compact: true)
                    } else {
                        ForEach(Array(store.latest.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(4))) { item in
                            GLProcessRow(process: item, showMemory: false)
                        }
                    }
                    Button { page = .apps } label: {
                        HStack { Text("查看全部应用"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(GLPalette.accent)
                    }.buttonStyle(.plain).padding(.top, 6)
                }
            }
            if store.settings.showSensors { sensorCard }
        }
    }

    private var sensorCard: some View {
        GLCard {
            GLSectionTitle(title: "机身状态", detail: store.latest.uptime > 0 ? "运行 \(Format.duration(store.latest.uptime))" : "等待系统采样")
            HStack(alignment: .top, spacing: 22) {
                GLSensor(label: "CPU 温度", value: store.latest.cpuTemperature.map { String(format: "%.0f °C", $0) }, fallback: "当前机型未提供")
                GLSensor(label: "CPU 功耗", value: store.latest.cpuPower.map { String(format: "%.1f W", $0) }, fallback: "接口不可用")
                GLSensor(label: "GPU 占用", value: store.latest.gpuPercent.map { Format.percent($0) }, fallback: "接口不可用")
                GLSensor(label: "风扇", value: store.latest.fanRPM.map { String(format: "%.0f RPM", $0) }, fallback: "无风扇或未提供")
                GLSensor(label: "系统热状态", value: hasLiveSample ? store.latest.thermalState : nil, fallback: "等待采样")
            }
            if let battery = store.latest.batteryPercent {
                Divider().opacity(0.5).padding(.vertical, 2)
                HStack(spacing: 8) {
                    Image(systemName: store.latest.batteryCharging ? "battery.100.bolt" : "battery.75").foregroundStyle(GLPalette.accent)
                    Text("电池 \(Format.percent(battery))\(store.latest.batteryCharging ? " · 充电中" : "")")
                    Spacer()
                    if let health = store.latest.batteryHealth { Text("健康度 \(Format.percent(health))") }
                    if let cycles = store.latest.batteryCycles { Text("· \(cycles) 次循环") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var sortedProcesses: [ProcessMetric] {
        store.latest.processes.filter { searchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchQuery) }
            .sorted { appSort == "cpu" ? $0.cpuPercent > $1.cpuPercent : $0.memoryBytes > $1.memoryBytes }
    }

    private var applications: some View {
        VStack(spacing: 16) {
            HStack(spacing: 15) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索应用或进程", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary).help("清除搜索").accessibilityLabel("清除应用搜索") }
                }.padding(10).background(GLPalette.card, in: RoundedRectangle(cornerRadius: 9))
                Picker("应用排序方式", selection: $appSort) { Text("CPU").tag("cpu"); Text("内存").tag("memory") }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
            }
            GLCard {
                GLProcessColumns {
                    Text("应用 / 进程 · \(sortedProcesses.count) 项").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("内存").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("进程数").frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Divider().padding(.vertical, 3)
                if sortedProcesses.isEmpty {
                    GLEmptyState(icon: searchQuery.isEmpty && store.isPaused ? "pause.circle" : "magnifyingglass",
                                 title: searchQuery.isEmpty ? (store.isPaused ? "采样已暂停" : "等待应用采样") : "没有找到匹配的应用",
                                 detail: searchQuery.isEmpty ? (store.isPaused ? "恢复采样后显示应用资源排行。" : "首次 CPU 统计需要连续两次采样。") : "试试其他应用名称。")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedProcesses) { process in
                            GLProcessColumns {
                                HStack(spacing: 10) {
                                    GLAppIcon(path: process.path, size: 28).accessibilityHidden(true)
                                    Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(process.path ?? process.name)
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(String(format: "%.1f%%", process.cpuPercent)).frame(maxWidth: .infinity, alignment: .trailing).foregroundStyle(process.cpuPercent > 30 ? GLPalette.amber : Color.primary)
                                Text(Format.bytes(process.memoryBytes)).frame(maxWidth: .infinity, alignment: .trailing)
                                Text("\(process.pids.count)").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                            }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(process.name)
                                .accessibilityValue("CPU \(String(format: "%.1f%%", process.cpuPercent))，内存 \(Format.bytes(process.memoryBytes))，\(process.pids.count) 个进程")
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            HStack {
                Text("按应用聚合可识别的进程；CPU 以整台 Mac 为 100%。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("打开活动监视器") { store.openActivityMonitor() }.font(.system(size: 11)).buttonStyle(.borderless)
            }
        }
    }

    private var historySamples: [MetricsSample] {
        let anchor = store.focusedEvent?.date ?? Date()
        let lower = anchor.addingTimeInterval(-Double(historyMinutes) * 60)
        let upper = store.focusedEvent != nil ? anchor.addingTimeInterval(300) : Date()
        let source = store.focusedEvent != nil ? store.eventHistory : store.history
        return source.filter { $0.timestamp >= lower && $0.timestamp <= upper }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("时间范围", selection: $historyMinutes) {
                    Text("10 分钟").tag(10); Text("1 小时").tag(60); Text("24 小时").tag(1440)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                Spacer()
                Button { store.exportHistory(minutes: historyMinutes, eventDate: store.focusedEvent?.date) } label: {
                    Label(store.focusedEvent == nil ? "导出近 \(selectedTimeLabel)" : "导出所示范围", systemImage: "square.and.arrow.up")
                }.controlSize(.small)
                    .help((store.focusedEvent == nil ? "导出最近 \(selectedTimeLabel)" : "导出事件前 \(selectedTimeLabel) 至事件后 5 分钟") + "时间范围内已保存的采样，历史通常每 10 秒保存一次。")
                    .disabled(store.dataBusy)
            }
            if let event = store.focusedEvent {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "scope").foregroundStyle(GLPalette.amber)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在回看：\(event.title)").font(.system(size: 12, weight: .medium))
                        Text("\(event.date.formatted(date: .abbreviated, time: .standard)) · 显示事件前所选时长及之后 5 分钟").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("回到现在") { store.focusedEvent = nil }.controlSize(.small)
                }.padding(14).background(GLPalette.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            GLCard {
                GLSectionTitle(title: "资源时间线", detail: "\(historySamples.count) 个数据点")
                GLTrendChart(samples: historySamples, metric: .cpu, title: "CPU 占用", color: GLPalette.accent, height: 125, eventDate: store.focusedEvent?.date, isPaused: store.isPaused)
                Divider().opacity(0.4).padding(.vertical, 3)
                GLTrendChart(samples: historySamples, metric: .memory, title: "内存占用", color: GLPalette.blue, height: 125, eventDate: store.focusedEvent?.date, isPaused: store.isPaused)
                Text("较长的采样空档会留白；历史通常每 10 秒保存一次。导出包含所选时间范围内已保存的记录。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GLCard {
                GLSectionTitle(title: "异常事件", detail: store.events.isEmpty ? "记录变化，辅助定位" : "显示最近 \(min(store.events.count, 100)) 条")
                if store.events.isEmpty {
                    GLEmptyState(icon: "tray", title: "暂无异常事件记录", detail: "持续高负载、内存压力或空间不足时，会在这里留下记录。", compact: true)
                } else {
                    ForEach(Array(store.events.sorted { $0.date > $1.date }.prefix(100))) { event in
                        let appearance = GLEventAppearance(severity: event.severity)
                        Button { store.focusEvent(event) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: appearance.icon).foregroundStyle(appearance.color).frame(width: 22).padding(.top, 2).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(event.title).font(.system(size: 12, weight: .semibold))
                                        GLPill(text: appearance.label, color: appearance.color)
                                        Spacer()
                                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                    Text(event.detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 5)
                            }.padding(.vertical, 10).padding(.horizontal, 6)
                                .background(store.focusedEvent?.id == event.id ? appearance.color.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help("回看此事件前后的资源变化")
                        Divider().opacity(0.35)
                    }
                }
                Text("事件依据已采集的数据生成，时间上的相关变化不等于因果结论。").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 4)
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 18) {
            GLCard {
                if let active = store.activeSession {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            GLPill(text: store.isPaused ? "采样已暂停" : "记录中", color: store.isPaused ? GLPalette.amber : GLPalette.accent)
                            Text(active.name).font(.system(size: 22, weight: .semibold)).lineLimit(2).help(active.name)
                            if store.isPaused { Text("任务计时继续；恢复采样后继续记录资源。").font(.system(size: 11)).foregroundStyle(.secondary) }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Format.duration(context.date.timeIntervalSince(active.start))).font(.system(size: 30, weight: .light, design: .monospaced)).monospacedDigit()
                            }
                        }
                        Spacer()
                        Button { store.endSession() } label: { Label("结束记录", systemImage: "stop.fill") }.buttonStyle(.borderedProminent)
                    }
                    Divider().padding(.vertical, 5)
                    HStack {
                        GLSensor(label: "CPU 峰值", value: active.sampleCount > 0 ? Format.percent(active.peakCPU) : nil, fallback: "等待采样")
                        GLSensor(label: "CPU 平均", value: active.sampleCount > 0 ? Format.percent(active.averageCPU) : nil, fallback: "等待采样")
                        GLSensor(label: "内存峰值", value: active.peakMemory > 0 ? Format.bytes(active.peakMemory) : nil, fallback: "等待采样")
                        GLSensor(label: "采样数量", value: "\(active.sampleCount)", fallback: "等待采样")
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "record.circle").font(.system(size: 32, weight: .light)).foregroundStyle(GLPalette.accent).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("开始一段任务记录").font(.system(size: 18, weight: .semibold))
                            Text("从现在起，记录这项工作的时长、CPU 与内存峰值。").font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                TextField("例如：编译项目 / 视频导出", text: $sessionName).textFieldStyle(.roundedBorder).onSubmit(startSession)
                                Button("开始记录", action: startSession).buttonStyle(.borderedProminent)
                            }.padding(.top, 10)
                        }
                    }
                }
            }
            GLSectionTitle(title: "已完成的任务", detail: "保存在这台 Mac 上")
            let completed = store.sessions.filter { $0.end != nil }.sorted { $0.start > $1.start }
            if completed.isEmpty {
                GLCard { GLEmptyState(icon: "tray", title: "第一份记录，从下一项工作开始", detail: "结束任务后，可以在这里查看汇总并导出。") }
            } else {
                ForEach(completed) { session in
                    GLCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).help(session.name)
                                Text(session.start.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                if session.interrupted == true {
                                    Label("上次运行中断，已恢复至最后采样", systemImage: "arrow.clockwise.circle")
                                        .font(.system(size: 10)).foregroundStyle(GLPalette.amber)
                                }
                            }
                            Spacer()
                            Text(Format.duration(session.duration)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                            Button { store.exportSession(session) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless).help("导出任务记录").accessibilityLabel("导出任务：\(session.name)")
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
            }
        }
    }

    private func startSession() {
        guard !store.dataBusy else { return }
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.startSession(name: name.isEmpty ? "任务 \(Date().formatted(date: .omitted, time: .shortened))" : name)
        sessionName = ""
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                GLMetricCard(title: "下载", icon: "arrow.down", value: Format.rate(store.latest.networkDown), detail: "当前接收速率", color: GLPalette.accent, values: store.history.suffix(50).compactMap(\.networkDown))
                GLMetricCard(title: "上传", icon: "arrow.up", value: Format.rate(store.latest.networkUp), detail: "当前发送速率", color: GLPalette.blue, values: store.history.suffix(50).compactMap(\.networkUp))
            }
            GLCard {
                GLSectionTitle(title: "连接诊断", detail: "仅在你点击时检查")
                Text("输入域名，检查本地连接、网关、域名解析与 HTTPS 服务。也可使用 IPv4 地址，但目标证书可能不支持直接 IP 访问。").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    TextField("域名，例如 www.apple.com", text: $diagnosticHost).textFieldStyle(.roundedBorder).onSubmit { if !store.isDiagnosing { store.runNetworkDiagnostics(host: diagnosticHost) } }
                    Button { store.runNetworkDiagnostics(host: diagnosticHost) } label: {
                        HStack(spacing: 7) {
                            if store.isDiagnosing { ProgressView().controlSize(.small) }
                            Text(store.isDiagnosing ? "正在检查" : "开始诊断")
                        }
                    }.buttonStyle(.borderedProminent).disabled(store.isDiagnosing || diagnosticHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.vertical, 6)
                if store.networkChecks.isEmpty {
                    GLEmptyState(icon: "network", title: "准备好检查连接", detail: "诊断会连接输入的目标地址，结果会显示在这里。", compact: true)
                } else {
                    ForEach(store.networkChecks) { check in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: check.success == true ? "checkmark.circle.fill" : check.success == false ? "exclamationmark.circle.fill" : "minus.circle")
                                .foregroundStyle(check.success == true ? GLPalette.accent : check.success == false ? GLPalette.amber : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(check.title).font(.system(size: 12, weight: .semibold))
                                Text(check.detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }.padding(.vertical, 10)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

}

/// Every application row and its header use these same columns. A custom layout
/// keeps a long process name from negotiating different widths in a LazyVStack.
struct GLProcessColumns: Layout {
    static let numericWidths: [CGFloat] = [82, 108, 60]
    static let spacing: CGFloat = 14

    private func widths(for available: CGFloat) -> [CGFloat] {
        let fixed = Self.numericWidths.reduce(0, +) + Self.spacing * 3
        return [max(0, available - fixed)] + Self.numericWidths
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? 600
        let width = proposedWidth.isFinite ? max(proposedWidth, 0) : 600
        let columns = widths(for: width)
        let height = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: columns[min(index, 3)], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(for: bounds.width)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            let width = columns[min(index, 3)]
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + Self.spacing
        }
    }
}

struct GLEventAppearance {
    let severity: String
    private var normalized: String { severity.lowercased() }
    private var critical: Bool { ["严重", "危急", "紧急", "critical", "error"].contains(normalized) }
    private var warning: Bool { ["关注", "警告", "warning", "warn"].contains(normalized) }
    var label: String {
        if critical { return "严重" }
        if warning { return "关注" }
        if ["info", "informational", "提醒"].contains(normalized) { return "提醒" }
        return severity
    }
    var color: Color { critical ? .red : warning ? GLPalette.amber : GLPalette.blue }
    var icon: String { critical ? "exclamationmark.triangle.fill" : warning ? "exclamationmark.circle.fill" : "info.circle" }
}

struct GLCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(GLPalette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.035), lineWidth: 1))
    }
}

struct GLSectionTitle: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.bottom, 3)
    }
}

struct GLMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    let color: Color
    let values: [Double]
    var body: some View {
        GLCard {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color.opacity(0.8))
            }
            Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            GLSparkline(values: values, color: color).frame(height: 29).padding(.top, 3)
        }
    }
}

struct GLSparkline: View {
    let values: [Double]
    var color: Color = GLPalette.accent
    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let upper = max(values.max() ?? 1, 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * Double(index) / Double(values.count - 1), y: size.height - max(0, value) / upper * (size.height - 3) - 1)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.16), color.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("近期变化趋势")
    }
}

enum GLChartMetric { case cpu, memory }

struct GLChartPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
    let segment: Int
}

enum GLChartPresentation {
    /// Reduce rendering cost while retaining each bucket's extrema and every
    /// segment endpoint. This transforms chart points only, never saved records.
    static func points(from samples: [MetricsSample], metric: GLChartMetric, targetCount: Int = 300) -> [GLChartPoint] {
        var all: [GLChartPoint] = []
        var segment = 0
        var previous: Date?
        for (index, sample) in samples.enumerated() {
            let value = metric == .cpu ? sample.cpuPercent : (sample.memoryTotal > 0 ? sample.memoryPercent : nil)
            guard let value, value.isFinite else {
                if previous != nil { segment += 1 }
                previous = nil
                continue
            }
            if let previous, sample.timestamp.timeIntervalSince(previous) > 120 { segment += 1 }
            all.append(GLChartPoint(id: index, timestamp: sample.timestamp, value: value, segment: segment))
            previous = sample.timestamp
        }
        guard all.count > targetCount else { return all }
        let bucketSize = max(1, Int(ceil(Double(all.count) / Double(max(targetCount / 2, 1)))))
        var kept = Set([0, all.count - 1])
        for start in stride(from: 0, to: all.count, by: bucketSize) {
            let end = min(start + bucketSize, all.count)
            var minimum = start
            var maximum = start
            for index in start..<end {
                if all[index].value < all[minimum].value { minimum = index }
                if all[index].value > all[maximum].value { maximum = index }
                if index > 0, all[index].segment != all[index - 1].segment {
                    kept.insert(index - 1); kept.insert(index)
                }
            }
            kept.insert(minimum); kept.insert(maximum)
        }
        return kept.sorted().map { all[$0] }
    }
}

struct GLTrendChart: View {
    let samples: [MetricsSample]
    let metric: GLChartMetric
    let title: String
    let color: Color
    var height: CGFloat = 130
    var eventDate: Date? = nil
    var isPaused = false
    private var timeFormat: Date.FormatStyle {
        if let first = samples.first?.timestamp, let last = samples.last?.timestamp,
           !Calendar.current.isDate(first, inSameDayAs: last) {
            return .dateTime.month().day().hour().minute()
        }
        return .dateTime.hour().minute()
    }
    var body: some View {
        let points = GLChartPresentation.points(from: samples, metric: metric)
        let segmentCounts = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("%").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if points.isEmpty {
                Text(eventDate != nil ? "当前回看范围没有历史采样" : isPaused ? "采样已暂停，恢复后显示趋势" : "正在等待有效采样")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: height)
            } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("时间", point.timestamp), y: .value("占用", point.value),
                                 series: .value("采样段", point.segment), stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.12), color.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.timestamp), y: .value("占用", point.value),
                                 series: .value("采样段", point.segment))
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        if segmentCounts[point.segment] == 1 {
                            PointMark(x: .value("时间", point.timestamp), y: .value("占用", point.value)).foregroundStyle(color).symbolSize(18)
                        }
                    }
                    if let eventDate { RuleMark(x: .value("事件", eventDate)).foregroundStyle(GLPalette.amber).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.055)); AxisValueLabel().font(.system(size: 8)).foregroundStyle(Color.secondary) } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: timeFormat).font(.system(size: 9)).foregroundStyle(Color.secondary) } }
                .frame(height: height)
            }
        }.frame(maxWidth: .infinity)
    }
}

struct GLValueRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(minLength: 8); Text(value).monospacedDigit() }.font(.system(size: 11))
    }
}

struct GLPill: View {
    let text: String
    let color: Color
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.09), in: Capsule()) }
}

struct GLSensor: View {
    let label: String
    let value: String?
    let fallback: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if value == nil { Text(fallback).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GLAppIcon: View {
    let path: String?
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let path, !path.isEmpty { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable() }
            else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary).padding(3) }
        }.frame(width: size, height: size)
    }
}

struct GLProcessRow: View {
    let process: ProcessMetric
    var showMemory = true
    var body: some View {
        HStack(spacing: 9) {
            GLAppIcon(path: process.path)
            Text(process.name).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1f%%", process.cpuPercent)).font(.system(size: 11, weight: .medium, design: .monospaced))
                if showMemory { Text(Format.bytes(process.memoryBytes)).font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
        }.padding(.vertical, 4)
    }
}

struct GLEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 9 : 13) {
            Image(systemName: icon).font(.system(size: compact ? 25 : 34, weight: .light)).foregroundStyle(GLPalette.accent.opacity(0.55))
            Text(title).font(.system(size: compact ? 12 : 14, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
        }.frame(maxWidth: .infinity).padding(.vertical, compact ? 17 : 38).padding(.horizontal, 10)
    }
}

struct GLSettingsRow<Content: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12))
                if !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer()
            content
        }.padding(.vertical, 4)
    }
}

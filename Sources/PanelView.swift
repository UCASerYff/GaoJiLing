import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: MonitorStore
    var openDashboard: () -> Void
    var contentHeightChanged: (CGFloat) -> Void
    var panelDragBegan: (NSPoint) -> Void
    var panelDragged: (NSPoint) -> Void
    var panelDragEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    cpuHero
                        .overlay(PanelDragArea(began: panelDragBegan, moved: panelDragged, ended: panelDragEnded)
                            .accessibilityHidden(true))
                        .help("按住 CPU 展示区域可移动面板，靠近左右侧边自动吸附。")
                    compactMemory
                    HStack(spacing: 12) {
                        networkMetric("下载", icon: "arrow.down", rate: store.latest.networkDown,
                                      values: store.history.suffix(35).compactMap(\.networkDown), color: GLPalette.accent)
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1, height: 42).accessibilityHidden(true)
                        networkMetric("上传", icon: "arrow.up", rate: store.latest.networkUp,
                                      values: store.history.suffix(35).compactMap(\.networkUp), color: GLPalette.blue)
                    }.padding(12).background(GLPalette.card, in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("活跃应用").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("CPU · 全机口径").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if store.latest.processes.isEmpty {
                            Text(hasSample ? "暂未获取应用数据" : "等待应用采样…")
                                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 9)
                        } else {
                            ForEach(Array(store.latest.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3))) { item in GLProcessRow(process: item) }
                        }
                    }
                    if store.settings.showSensors {
                        VStack(spacing: 10) {
                            Divider().opacity(0.4)
                            HStack(alignment: .top, spacing: 10) {
                                sensor("CPU 温度", value: store.latest.cpuTemperature.map { String(format: "%.0f °C", $0) })
                                sensor("热状态", value: hasSample ? store.latest.thermalState : nil)
                                if let battery = store.latest.batteryPercent {
                                    sensor(store.latest.batteryCharging ? "电池 · 充电中" : "电池", value: Format.percent(battery))
                                } else {
                                    sensor("磁盘可用", value: store.latest.diskTotal > 0 ? Format.bytes(store.latest.diskFree) : nil)
                                }
                            }
                        }
                    }
                    if let active = store.activeSession {
                        HStack(spacing: 7) {
                            Circle().fill(GLPalette.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                            Text(active.name).lineLimit(1).help(active.name)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Format.duration(context.date.timeIntervalSince(active.start))).monospacedDigit()
                                    .accessibilityLabel("任务持续时间")
                                    .accessibilityValue(Format.duration(context.date.timeIntervalSince(active.start)))
                            }
                        }.font(.system(size: 11)).foregroundStyle(GLPalette.accent).padding(10).background(GLPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: PanelHeightPreference.self, value: ["content": geometry.size.height])
                    })
            }
            Divider().opacity(0.5)
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(store.isPaused ? GLPalette.amber : GLPalette.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(store.dataBusy ? "处理资料中" : store.isPaused ? "已暂停" : hasSample ? "实时监控" : "等待采样")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(store.isPaused ? "已暂停采样，保留最后一次读数" : "监控数据保存在本机")
                Button { store.togglePause() } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11)).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(store.dataBusy)
                .help(store.dataBusy ? "资料处理完成后可调整采样状态" : store.isPaused ? "恢复采样" : "暂停采样")
                .accessibilityLabel(store.isPaused ? "恢复采样" : "暂停采样")
                Spacer(minLength: 4)
                Button(action: openDashboard) {
                    HStack(spacing: 6) { Text("打开主窗口"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).frame(minHeight: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(GLPalette.accent).accessibilityLabel("打开搞机灵主窗口")
            }.padding(.horizontal, 22).padding(.vertical, 9)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PanelHeightPreference.self, value: ["footer": geometry.size.height])
                })
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(GLPalette.canvas)
        .tint(GLPalette.accent)
        .onPreferenceChange(PanelHeightPreference.self) { heights in
            guard let content = heights["content"], let footer = heights["footer"] else { return }
            contentHeightChanged(ceil(content + footer + 1))
        }
    }

    private var cpuHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU 占用").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(Format.percent(store.latest.cpuPercent)).font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
                        .accessibilityLabel("全机 CPU 占用").accessibilityValue(store.latest.cpuPercent.map { Format.percent($0) } ?? unavailableText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(store.isPaused ? "已暂停采样" : store.latest.cpuPercent.map { $0 < 30 ? "从容运行" : $0 < 75 ? "正在忙碌" : "全力以赴" } ?? unavailableText)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(store.isPaused ? GLPalette.amber : GLPalette.accent)
                    Text(store.latest.corePercents.isEmpty ? "核心数据\(hasSample ? "不可用" : "待采样")" : "\(store.latest.corePercents.count) 核心")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            GLSparkline(values: store.history.suffix(45).compactMap(\.cpuPercent)).frame(height: 30).accessibilityLabel("CPU 占用近期趋势")
            if !store.latest.corePercents.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(store.latest.corePercents.enumerated()), id: \.offset) { _, value in
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(GLPalette.accent.opacity(0.08))
                                Capsule().fill(GLPalette.accent.opacity(0.6)).frame(width: max(2, geometry.size.width * min(max(value, 0), 100) / 100))
                            }
                        }.frame(height: 4)
                    }
                }.padding(.top, 3).help("各 CPU 核心的当前占用")
            }
        }
    }

    private var compactMemory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("内存").font(.system(size: 11, weight: .semibold))
                Spacer()
                GLPill(text: hasMemory ? "压力 · \(store.latest.memoryPressure)" : unavailableText,
                       color: hasMemory ? GLPalette.pressure(store.latest.memoryPressure) : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hasMemory ? Format.bytes(store.latest.memoryUsed) : "—").font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                Text(hasMemory ? "/ \(Format.bytes(store.latest.memoryTotal))" : "/ —").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(hasMemory ? "Swap \(Format.bytes(store.latest.swapUsed))" : "Swap —").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if hasMemory {
                ProgressView(value: min(max(store.latest.memoryPercent / 100, 0), 1)).tint(GLPalette.blue)
                    .accessibilityLabel("内存使用率").accessibilityValue(Format.percent(store.latest.memoryPercent))
            } else {
                Capsule().fill(Color.primary.opacity(0.06)).frame(height: 4).accessibilityHidden(true)
            }
        }.padding(12).background(GLPalette.card, in: RoundedRectangle(cornerRadius: 13))
    }

    private var hasMemory: Bool { store.latest.memoryTotal > 0 }
    private var hasSample: Bool {
        hasMemory || store.latest.uptime > 0 || store.latest.diskTotal > 0 || store.latest.processCount > 0 || !store.latest.corePercents.isEmpty
    }
    private var unavailableText: String { hasSample ? "不可用" : "等待采样" }

    private func networkMetric(_ label: String, icon: String, rate: Double?, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(label, systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                Text(Format.rate(rate)).font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    .accessibilityLabel(label + "速度").accessibilityValue(rate.map { Format.rate($0) } ?? unavailableText)
                Spacer(minLength: 0)
                GLSparkline(values: values, color: color).frame(width: 32, height: 18)
                    .accessibilityLabel(label + "速度近期趋势")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sensor(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: 16, weight: .medium, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if value == nil { Text(unavailableText).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value ?? unavailableText)
    }
}

/// Desktop coordinates keep the gesture stable while its window moves.
/// Only the CPU display captures dragging; buttons and other scroll content
/// retain their normal mouse handling.
private struct PanelDragArea: NSViewRepresentable {
    var began: (NSPoint) -> Void
    var moved: (NSPoint) -> Void
    var ended: () -> Void
    func makeNSView(context: Context) -> PanelDragView { PanelDragView() }
    func updateNSView(_ view: PanelDragView, context: Context) {
        view.began = began; view.moved = moved; view.ended = ended
    }
}

private final class PanelDragView: NSView {
    var began: ((NSPoint) -> Void)?
    var moved: ((NSPoint) -> Void)?
    var ended: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { began?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { moved?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { ended?() }
}

private struct PanelHeightPreference: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

import SwiftUI
import AppKit

enum GLSettingsTab: String {
    case module, appearance, data, about

    init?(destination: String) {
        if destination == "settings" { self = .module }
        else if let tab = Self(rawValue: destination) { self = tab }
        else { return nil }
    }
}

@MainActor final class GLSettingsNavigation: ObservableObject {
    @Published var selectedTab: GLSettingsTab = .module
}

/// Shared navigation is owned by the AppKit window controller, so opening an
/// existing settings window can select a tab without rebuilding its contents.
struct GLSettingsWindowView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var navigation: GLSettingsNavigation

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $navigation.selectedTab) {
                GLSettingsView(store: store)
                    .disabled(store.dataBusy)
                    .tabItem { Label("模块设置", systemImage: "slider.horizontal.3") }
                    .tag(GLSettingsTab.module)
                GLAppearanceSettingsView(store: store)
                    .disabled(store.dataBusy)
                    .tabItem { Label("外观", systemImage: "paintpalette") }
                    .tag(GLSettingsTab.appearance)
                GLDataSettingsView(store: store)
                    .disabled(store.dataBusy)
                    .tabItem { Label("数据", systemImage: "externaldrive") }
                    .tag(GLSettingsTab.data)
                GLAboutView(store: store)
                    .disabled(store.dataBusy)
                    .tabItem { Label("关于", systemImage: "info.circle") }
                    .tag(GLSettingsTab.about)
            }
            .padding(.top, 10)

            if store.dataBusy || !(store.statusMessage ?? "").isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    if store.dataBusy {
                        ProgressView().controlSize(.small).padding(.top, 2)
                    } else {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).padding(.top, 2)
                    }
                    Text((store.statusMessage?.isEmpty == false ? store.statusMessage : nil) ?? "正在处理本地资料，请稍候…")
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !store.dataBusy {
                        Button { store.statusMessage = nil } label: {
                            Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle())
                        }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("关闭操作提示").accessibilityLabel("关闭操作提示")
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 13)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(GLPalette.accent)
        .frame(minWidth: 660, minHeight: 560)
    }
}

struct GLSettingsView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        Form {
            Section {
                Toggle("显示可移动唤起条", isOn: setting(\.edgeEnabled))
                Picker("停靠侧边", selection: setting(\.edge)) {
                    Text("左侧").tag("left")
                    Text("右侧").tag("right")
                }
                LabeledContent("唤起悬停时间") {
                    HStack(spacing: 10) {
                        Slider(value: setting(\.edgeDelay), in: 0.2...1.5, step: 0.05)
                            .frame(width: 145)
                            .accessibilityLabel("唤起条悬停时间")
                            .accessibilityValue(String(format: "%.2f 秒", store.settings.edgeDelay))
                        Text(String(format: "%.2f 秒", store.settings.edgeDelay))
                            .monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("唤起条位置") {
                    Button("重置到当前屏幕中间") {
                        guard !store.dataBusy else { return }
                        NotificationCenter.default.post(name: .monitorResetEdgeHandle, object: nil)
                    }
                }
                Picker("呼出快捷键", selection: setting(\.hotkeyChoice)) {
                    Text("⌥ Option + ⌘ Command + G").tag("g")
                    Text("⌥ Option + ⌘ Command + M").tag("m")
                }
            } header: {
                Text("边缘唤起条")
            } footer: {
                Text("点击细线或在上面停留即可呼出面板。按住拖动可调整高度、侧边或屏幕，松开后自动贴边并记住位置。隐藏唤起条后，仍可用快捷键或菜单栏打开面板。")
            }

            Section {
                Picker("采样间隔", selection: setting(\.sampleInterval)) {
                    ForEach(sampleIntervals, id: \.self) { value in
                        Text(value.formatted(.number.precision(.fractionLength(0...1))) + " 秒").tag(value)
                    }
                }
                Picker("历史保留", selection: setting(\.retentionDays)) {
                    ForEach(retentionOptions, id: \.self) { value in Text("\(value) 天").tag(value) }
                }
                Toggle("异常通知", isOn: Binding(get: { store.settings.notificationsEnabled }, set: { value in
                    guard !store.dataBusy else { return }
                    store.settings.notificationsEnabled = value
                    store.requestNotifications()
                }))
            } header: {
                Text("观察与保存")
            } footer: {
                Text("较长的采样间隔可以降低后台开销。回看显示最近 24 小时；导出可选择已保存的全部记录。历史约每 10 秒保存一次，超过一天的旧记录按分钟保留，任务记录独立保留。")
            }

            Section {
                Toggle("登录时启动", isOn: Binding(get: { store.settings.launchAtLogin }, set: { value in
                    guard !store.dataBusy else { return }
                    store.setLoginEnabled(value)
                }))
            } header: {
                Text("启动")
            } footer: {
                Text("关闭主窗口后继续在菜单栏监控；完全退出请按 ⌘Q。")
            }
        }
        .formStyle(.grouped)
    }

    private var sampleIntervals: [Double] {
        Array(Set([1.0, 2, 3, 5, 10, store.settings.sampleInterval])).sorted()
    }
    private var retentionOptions: [Int] {
        Array(Set([1, 7, 14, 30, store.settings.retentionDays])).sorted()
    }
    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: {
            guard !store.dataBusy else { return }
            store.settings[keyPath: keyPath] = $0
            store.saveSettings()
        })
    }
}

struct GLAppearanceSettingsView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: setting(\.appearance)) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                LabeledContent("语言", value: "简体中文")
            }
            Section {
                Toggle("显示传感器区域", isOn: setting(\.showSensors))
                Toggle("在菜单栏显示 CPU 占用", isOn: setting(\.menuBarCPU))
            } header: {
                Text("监控显示")
            } footer: {
                Text("传感器可用性取决于机型与系统。首次读取前显示等待采样，无法读取的指标显示不可用。")
            }
        }
        .formStyle(.grouped)
    }

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: {
            guard !store.dataBusy else { return }
            store.settings[keyPath: keyPath] = $0
            store.saveSettings()
        })
    }
}

struct GLDataSettingsView: View {
    @ObservedObject var store: MonitorStore
    @State private var exportDays = 0

    var body: some View {
        Form {
            Section("本地资料") {
                LabeledContent("已保存记录") {
                    Text(store.dataSummaryText).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("数据库占用", value: store.dataSizeText)
                HStack {
                    Button("打开数据文件夹", action: store.revealDataFolder)
                    Button("刷新", action: store.refreshDataSummary)
                    Spacer()
                    if store.lastExportURL != nil {
                        Button("显示最近导出的文件", action: store.revealLastExport)
                    }
                }
            }
            Section {
                Picker("导出范围", selection: $exportDays) {
                    Text("全部已保存记录").tag(0)
                    Text("最近 24 小时").tag(1)
                    Text("最近 7 天").tag(7)
                    Text("最近 30 天").tag(30)
                }
                exportRow("监控记录", detail: "CPU、内存、网络、磁盘、温度和电池", icon: "waveform.path.ecg", kind: "history")
                exportRow("异常事件", detail: "发生时间、标题、级别与观测详情", icon: "exclamationmark.bubble", kind: "events")
                exportRow("任务汇总", detail: "工作时长、平均负载和资源峰值", icon: "record.circle", kind: "sessions")
            } header: {
                Text("导出表格")
            } footer: {
                Text("CSV 可用 Excel 或 Numbers 打开。任务按开始时间筛选，只导出已结束的记录。")
            }
            Section {
                    Text("包含全部已保存的历史、异常事件、任务、应用设置和唤起条位置。恢复会替换当前记录，并先自动备份当前数据；请先结束正在记录的任务。")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(action: store.exportFullBackup) {
                        Label("导出完整备份…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: store.restoreFullBackup) {
                        Label("从备份恢复…", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("完整备份与恢复")
            } footer: {
                Text("JSON 备份提供 SHA-256 完整性校验，包含任务名和部分应用资源记录，请保存到你信任的位置。登录项和通知权限由本机系统管理。")
            }
            Section {
                DisclosureGroup("数据清理") {
                    Text("清理只针对所选记录，设置会保留。清理前建议先导出完整备份。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("清空历史采样…", role: .destructive) { store.clearSavedData(.history) }
                        Button("清空异常事件…", role: .destructive) { store.clearSavedData(.events) }
                        Button("清空已完成任务…", role: .destructive) { store.clearSavedData(.sessions) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if !store.dataBusy { store.refreshDataSummary() } }
    }

    private func exportRow(_ title: String, detail: String, icon: String, kind: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(GLPalette.accent).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("导出 CSV…") { store.exportTable(kind, days: exportDays) }
                .accessibilityLabel("导出" + title + " CSV")
        }
        .padding(.vertical, 3)
    }
}

struct GLAboutView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().frame(width: 76, height: 76).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text("搞机灵").font(.system(size: 25, weight: .semibold))
                            Text("V\(GLPalette.version)")
                                .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        }.lineLimit(1).accessibilityElement(children: .combine)
                        Text("原生 macOS 系统监控").foregroundStyle(.secondary)
                        Text("电脑的小动静，一眼就知道。").foregroundStyle(GLPalette.accent)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                LabeledContent("本机") {
                    Text(store.hardwareDescription).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Section("使用提示") {
                tip("唤起与收起", "点击或悬停竖线展开面板；鼠标进入后移出会快速收回，点击面板外或按 Esc 也可收起。只有面板内开始的拖动会暂缓收回。唤起悬停时间只控制展开等待，按住竖线可拖动位置。")
                tip("键盘操作", "\(store.settings.hotkeyChoice == "m" ? "⌥⌘M" : "⌥⌘G") 呼出面板 · ⌘, 打开设置 · ⇧⌘E 打开数据。")
                tip("数据口径", "CPU 使用全机 0–100% 口径。传感器因机型而异；无法获取时显示不可用。完全退出程序后不再采样，关闭窗口仍会继续监控。")
                tip("暂停采样", "暂停后保留最后一次读数；进行中的任务仍继续计时，需在任务页面点击结束记录。")
                HStack(spacing: 12) {
                    Button("完整使用说明", action: store.openGuide)
                    Button("打开活动监视器", action: store.openActivityMonitor)
                }
            }
            Section("隐私与许可") {
                Text("系统监控和历史处理均在本机完成，无账号、无云端同步、无 AI。网络诊断只在你主动运行时连接指定目标。")
                    .foregroundStyle(.secondary)
                Text("部分采集实现参考 Glance 和 Stats 的 MIT 许可代码。本版本为本地签名版本，尚未进行 Apple Developer ID 公证。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("查看开源许可", action: store.openNotices)
            }
        }
        .formStyle(.grouped)
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

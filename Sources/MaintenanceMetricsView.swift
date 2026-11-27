import SwiftUI
import ApplicationServices

private struct MaintenanceMetricRow: View {
    let title: String
    let reading: MetricReading<Double>?
    let now: Date

    var body: some View {
        let value: String = reading.flatMap { item in item.value.map { Self.format($0, unit: item.unit) } } ?? "不可用"
        let isStale: Bool = reading.map { $0.value != nil && !$0.isFresh(at: now) } ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit()
                if isStale { Text("过期").foregroundStyle(.orange).font(.caption) }
            }.font(.callout)
            if let reading {
                let source: String = maintenanceReadingSource(reading.source, at: reading.timestamp, reason: reading.availabilityReason)
                Text(source).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private static func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "bytes": return Format.bytes(value)
        case "bytes/s": return Format.bytes(value) + "/s"
        case "level": return [1: "正常", 2: "偏高", 4: "严重"][Int(value)] ?? "未知"
        default: return String(format: "%.1f", value) + " " + unit
        }
    }
}

private func maintenanceReadingSource(_ source: String, at date: Date, reason: String? = nil) -> String {
    let time: String = date.formatted(date: .omitted, time: .standard)
    let detail: String = reason.map { " · " + $0 } ?? ""
    return source + " · " + time + detail
}

private struct MaintenanceBatterySection: View {
    let snapshot: BatterySnapshot?
    @ObservedObject var maintenance: MaintenanceController
    let now: Date
    let blocked: Bool

    var body: some View {
        let showsChargeLimit: Bool = BatteryCapability.systemChargeLimitAvailable && snapshot?.present.value == true
        let notices: [(offset: Int, element: BatteryNotice)] = Array(maintenance.batteryNotices.enumerated())
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("电池与提醒").font(.headline)
                if let snapshot {
                    MaintenanceBatteryReadings(snapshot: snapshot, now: now)
                } else {
                    Text("尚未收到电池采样；没有电池或缺失字段不会填造零值。").foregroundStyle(.secondary)
                }
                Divider()
                MaintenanceBatteryReminderControls(maintenance: maintenance, blocked: blocked)
                Text("仅通知，不改变充电。电池温度缺失或过期时不触发温度提醒。").font(.caption).foregroundStyle(.secondary)
                if showsChargeLimit { MaintenanceSystemChargeLimit() }
                ForEach(notices, id: \.offset) { item in
                    Text(item.element.title + "：" + item.element.detail).font(.caption)
                }
                MaintenanceBatteryCapabilities()
            }.padding(8)
        }
    }
}

private struct MaintenanceBatteryReadings: View {
    let snapshot: BatterySnapshot
    let now: Date

    var body: some View {
        let presence: String = flag(snapshot.present, yes: "检测到电池", no: "未发现内置电池")
        let power: String = flag(snapshot.externalPower, yes: "外接电源", no: "电池供电")
        let charging: String = flag(snapshot.charging, yes: "正在充电", no: "未充电")
        let powerSource: String = maintenanceReadingSource(snapshot.externalPower.source, at: snapshot.externalPower.timestamp)
        let health = snapshot.healthCondition
        let healthSource: String = maintenanceReadingSource(health.source, at: health.timestamp, reason: health.availabilityReason)
        let healthStale: Bool = health.value != nil && !health.isFresh(at: now)
        let cycles = snapshot.cycles
        let cycleCount: String = cycles.value.map { String($0) } ?? "不可用"
        let cycleSource: String = maintenanceReadingSource(cycles.source, at: cycles.timestamp, reason: cycles.availabilityReason)
        let cyclesStale: Bool = cycles.value != nil && !cycles.isFresh(at: now)
        VStack(alignment: .leading, spacing: 10) {
            Group {
                MaintenanceBatteryStatusRow(title: "电池状态", value: presence)
                MaintenanceMetricRow(title: "电量", reading: snapshot.percent, now: now)
                MaintenanceBatteryStatusRow(title: "供电状态", value: power + " · " + charging)
                Text(powerSource).font(.caption2).foregroundStyle(.secondary)
                MaintenanceMetricRow(title: "健康百分比", reading: snapshot.healthPercent, now: now)
            }
            Group {
                MaintenanceBatteryStatusRow(title: "系统健康状态", value: health.value ?? "不可用", isStale: healthStale)
                Text(healthSource).font(.caption2).foregroundStyle(.secondary)
                MaintenanceBatteryStatusRow(title: "循环次数", value: cycleCount, isStale: cyclesStale)
                Text(cycleSource).font(.caption2).foregroundStyle(.secondary)
                MaintenanceMetricRow(title: "电池温度", reading: snapshot.temperature, now: now)
                MaintenanceMetricRow(title: "预计充满时间", reading: snapshot.minutesToFull, now: now)
                MaintenanceMetricRow(title: "预计用尽时间", reading: snapshot.minutesToEmpty, now: now)
            }
        }
    }

    private func flag(_ reading: MetricReading<Bool>, yes: String, no: String) -> String {
        guard let value = reading.value else { return "未知" }
        return (value ? yes : no) + (reading.isFresh(at: now) ? "" : "（过期）")
    }
}

private struct MaintenanceBatteryStatusRow: View {
    let title: String
    let value: String
    var isStale = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
            if isStale { Text("过期").foregroundStyle(.orange) }
        }.font(.callout)
    }
}

private struct MaintenanceBatteryReminderControls: View {
    @ObservedObject var maintenance: MaintenanceController
    let blocked: Bool

    var body: some View {
        let rule: BatteryRule = maintenance.preferences.batteryRule
        let enabled = Binding<Bool>(get: { maintenance.preferences.batteryRule.enabled }, set: { enabled in
            maintenance.update { $0.batteryRule.enabled = enabled }
        })
        let low = thresholdBinding(\.lowPercent)
        let high = thresholdBinding(\.highPercent)
        let temperature = thresholdBinding(\.highTemperature)
        let lowTitle: String = "低电量 \(Int(rule.lowPercent))%"
        let highTitle: String = "高电量 \(Int(rule.highPercent))%"
        let temperatureTitle: String = "温度提醒 \(Int(rule.highTemperature))°C"
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用电池阈值提醒", isOn: enabled).disabled(blocked)
            HStack {
                Stepper(lowTitle, value: low, in: 5.0...50.0, step: 5.0)
                Stepper(highTitle, value: high, in: 55.0...100.0, step: 5.0)
            }.disabled(blocked)
            HStack {
                Stepper(temperatureTitle, value: temperature, in: 30.0...70.0, step: 1.0)
                Spacer()
                Button("允许系统通知") { maintenance.requestNotificationAccess() }.disabled(blocked)
            }
        }
    }

    private func thresholdBinding(_ key: WritableKeyPath<BatteryRule, Double>) -> Binding<Double> {
        Binding(get: { maintenance.preferences.batteryRule[keyPath: key] }, set: { value in
            maintenance.update { $0.batteryRule[keyPath: key] = value }
        })
    }
}

private struct MaintenanceSystemChargeLimit: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("此系统版本提供原生充电上限设置，可由你在系统设置中选择。本应用不读取或更改该设定，未确认硬件控制生效。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开系统电池设置…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!) }
                Link("Apple 充电上限说明", destination: URL(string: "https://support.apple.com/en-us/102338")!)
            }.font(.caption)
        }
    }
}

private struct MaintenanceBatteryCapabilities: View {
    var body: some View {
        DisclosureGroup("充电控制能力与依据") {
            ForEach(BatteryCapability.current) { value in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(value.title); Spacer(); Text(value.capability.rawValue).foregroundStyle(.secondary) }
                    Text(value.detail).font(.caption).foregroundStyle(.secondary)
                    Link("官方依据", destination: URL(string: value.evidenceURL)!).font(.caption)
                }.padding(.vertical, 5)
            }
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var maintenance: MaintenanceController
    @State private var metricSelection = false
    private let metricNames: [(String, String)] = [
        ("cpu", "CPU 全机占用"), ("gpu", "GPU 占用"), ("memory", "已用内存"), ("compressed", "压缩内存"),
        ("swap", "Swap"), ("pressure", "内存压力"), ("temperature", "CPU 温度"), ("cpuPower", "CPU 功率"),
        ("gpuPower", "GPU 功率"), ("diskFree", "磁盘可用"), ("diskRead", "磁盘读取"), ("diskWrite", "磁盘写入"),
        ("networkDown", "网络下载"), ("networkUp", "网络上传")
    ]
    private var blocked: Bool { store.dataBusy || !maintenance.writable }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 18) {
                if let status = maintenance.status { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                resources(now: context.date)
                battery(now: context.date)
                fans(now: context.date)
                exitRules
            }
        }
    }
    private func resources(now: Date) -> some View {
        let visibleMetricIDs = maintenance.preferences.visibleMetricIDs
        let displayed = metricNames.filter { visibleMetricIDs.contains($0.0) }
        let age = now.timeIntervalSince(store.latest.timestamp)
        let thermalStatus = store.latest.readings == nil ? "未读取" : store.latest.thermalState + (age > 15 ? "（过期）" : "")
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("指标来源与新鲜度").font(.headline)
                    Spacer()
                    Button("选择展示指标") { metricSelection.toggle() }
                        .popover(isPresented: $metricSelection) { metricChoices }
                }
                Text("复用现有采样；保留旧值会标为过期，热状态不代表摄氏温度。").font(.caption).foregroundStyle(.secondary)
                ForEach(displayed, id: \.0) { id, title in
                    metricRow(title, reading: store.latest.readings?[id], now: now)
                }
                HStack { Text("系统热状态"); Spacer(); Text(thermalStatus) }.font(.callout)
                Text("移动端配对未实现；未启动局域网或公网服务。").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var metricChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(metricNames, id: \.0) { id, name in
                Toggle(name, isOn: visibleMetricBinding(id)).disabled(blocked)
            }
        }.padding(18)
    }
    private func visibleMetricBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { maintenance.preferences.visibleMetricIDs.contains(id) }, set: { enabled in
            maintenance.update { value in
                value.visibleMetricIDs.removeAll { $0 == id }
                if enabled { value.visibleMetricIDs.append(id) }
            }
        })
    }
    private func fans(now: Date) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("风扇与热管理").font(.headline)
                Text(FanCapabilities.description(model: Self.model, fans: store.latest.fanDescriptors)).font(.callout)
                ForEach(store.latest.fanDescriptors ?? []) { fan in metricRow(fan.name, reading: fan.speed, now: now) }
                Text("系统自动管理。未取得可验证的转速范围、控制 helper 或崩溃恢复能力，固定转速和曲线控制未开放。").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private static let model: String = {
        var buffer = [CChar](repeating: 0, count: 128)
        return gjl_sysctl_string("hw.model", &buffer, buffer.count) != 0 ? String(cString: buffer) : ""
    }()
    private func metricRow(_ title: String, reading: MetricReading<Double>?, now: Date) -> MaintenanceMetricRow {
        MaintenanceMetricRow(title: title, reading: reading, now: now)
    }
    private func battery(now: Date) -> MaintenanceBatterySection {
        MaintenanceBatterySection(snapshot: store.latest.batterySnapshot, maintenance: maintenance, now: now, blocked: blocked)
    }
    private var exitRules: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("后台应用正常退出").font(.headline)
                    Spacer()
                    if maintenance.isChecking { ProgressView().controlSize(.small) }
                    Button("添加应用规则") { maintenance.chooseApplication() }.disabled(blocked)
                }
                Toggle("主动启用自动退出", isOn: exitPreferenceBinding(\.appExitEnabled)).disabled(blocked)
                Toggle("暂停所有退出规则", isOn: exitPreferenceBinding(\.appExitPaused)).disabled(blocked)
                Text("默认停用；只有逐个启用的应用才参与。前台、未保存、保存状态未知、睡眠及受保护应用会跳过。保留原应用的保存提示，不强退，也不承诺释放多少内存。").font(.caption).foregroundStyle(.secondary)
                if !AXIsProcessTrusted() {
                    HStack {
                        Text("辅助功能权限未获准，无法确认保存状态；规则会跳过。").font(.caption)
                        Button("打开权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                    }
                }
                if maintenance.preferences.rules.isEmpty { Text("尚无规则。添加应用后仍需逐项启用。").foregroundStyle(.secondary) }
                ForEach(maintenance.preferences.rules) { rule in
                    exitRuleRow(rule)
                }
                DisclosureGroup("最近退出记录（仅本机）") {
                    if maintenance.preferences.records.isEmpty { Text("暂无退出请求。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(maintenance.preferences.records.reversed()) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name + " · " + record.outcome + " · " + record.date.formatted()).font(.caption)
                            Text(record.reason).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }.padding(8)
        }
    }
    private func exitRuleRow(_ rule: AppExitRule) -> some View {
        let enabled: Binding<Bool> = ruleBinding(rule, \.enabled)
        let trigger: Binding<AppExitTrigger> = ruleBinding(rule, \.trigger)
        let minutes: Binding<Double> = ruleBinding(rule, \.minutes)
        let memory: Binding<UInt64> = ruleBinding(rule, \.memoryBytes)
        let cooldown: Binding<Double> = ruleBinding(rule, \.cooldownSeconds)
        let memoryRange: ClosedRange<UInt64> = 16_777_216...137_438_953_472
        let memoryStep: UInt64.Stride = 268_435_456
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(rule.name, isOn: enabled)
                Spacer()
                Button("移除") { maintenance.update { $0.rules.removeAll { $0.id == rule.id } } }
            }
            Text(rule.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Picker("条件", selection: trigger) { ForEach(AppExitTrigger.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 240)
                Stepper("后台至少 \(Int(rule.minutes)) 分钟", value: minutes, in: 1...1440, step: 1)
            }
            if rule.trigger == .memory {
                Stepper("内存阈值 \(Format.bytes(Double(rule.memoryBytes)))", value: memory, in: memoryRange, step: memoryStep)
            }
            HStack {
                Stepper("冷却 \(Int(rule.cooldownSeconds / 60)) 分钟", value: cooldown, in: 60...86400, step: 60)
                Toggle("加入保护名单", isOn: protectedAppBinding(rule.bundleID))
            }
            Text(maintenance.ruleReasons[rule.id] ?? "启用后从新观察；不累计以前或休眠时间").font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)).disabled(blocked)
    }
    private func exitPreferenceBinding(_ key: WritableKeyPath<MaintenancePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { maintenance.preferences[keyPath: key] }, set: { value in
            maintenance.update { $0[keyPath: key] = value }
        })
    }
    private func protectedAppBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(get: { maintenance.preferences.protectedBundleIDs.contains(bundleID) }, set: { enabled in
            maintenance.update { value in
                value.protectedBundleIDs.removeAll { $0 == bundleID }
                if enabled { value.protectedBundleIDs.append(bundleID) }
            }
        })
    }
    private func ruleBinding<Value>(_ rule: AppExitRule, _ key: WritableKeyPath<AppExitRule, Value>) -> Binding<Value> {
        Binding(get: { (maintenance.preferences.rules.first { $0.id == rule.id } ?? rule)[keyPath: key] }, set: { value in
            maintenance.update { state in if let index = state.rules.firstIndex(where: { $0.id == rule.id }) { state.rules[index][keyPath: key] = value } }
        })
    }
}

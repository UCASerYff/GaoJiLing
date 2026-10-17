import SwiftUI
import ApplicationServices

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
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("指标来源与新鲜度").font(.headline)
                            Spacer()
                            Button("选择展示指标") { metricSelection.toggle() }.popover(isPresented: $metricSelection) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(metricNames, id: \.0) { id, name in
                                        Toggle(name, isOn: Binding(get: { maintenance.preferences.visibleMetricIDs.contains(id) }, set: { enabled in
                                            maintenance.update { value in
                                                value.visibleMetricIDs.removeAll { $0 == id }
                                                if enabled { value.visibleMetricIDs.append(id) }
                                            }
                                        })).disabled(blocked)
                                    }
                                }.padding(18)
                            }
                        }
                        Text("复用现有采样；保留旧值会标为过期，热状态不代表摄氏温度。").font(.caption).foregroundStyle(.secondary)
                        ForEach(metricNames.filter { maintenance.preferences.visibleMetricIDs.contains($0.0) }, id: \.0) { id, title in
                            metricRow(title, reading: store.latest.readings?[id], now: context.date)
                        }
                        HStack { Text("系统热状态"); Spacer(); Text(store.latest.readings == nil ? "未读取" : store.latest.thermalState + (context.date.timeIntervalSince(store.latest.timestamp) > 15 ? "（过期）" : "")) }
                            .font(.callout)
                        Text("移动端配对未实现；未启动局域网或公网服务。").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                battery(now: context.date)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("风扇与热管理").font(.headline)
                        Text(FanCapabilities.description(model: Self.model, fans: store.latest.fanDescriptors)).font(.callout)
                        ForEach(store.latest.fanDescriptors ?? []) { fan in metricRow(fan.name, reading: fan.speed, now: context.date) }
                        Text("系统自动管理。未取得可验证的转速范围、控制 helper 或崩溃恢复能力，固定转速和曲线控制未开放。").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                exitRules
            }
        }
    }
    private static let model: String = {
        var buffer = [CChar](repeating: 0, count: 128)
        return gjl_sysctl_string("hw.model", &buffer, buffer.count) != 0 ? String(cString: buffer) : ""
    }()
    private func metricRow(_ title: String, reading: MetricReading<Double>?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(reading?.value.map { format($0, unit: reading!.unit) } ?? "不可用").monospacedDigit()
                if reading?.value != nil && reading?.isFresh(at: now) != true { Text("过期").foregroundStyle(.orange).font(.caption) }
            }.font(.callout)
            if let reading {
                Text(reading.source + " · " + reading.timestamp.formatted(date: .omitted, time: .standard) + (reading.availabilityReason.map { " · " + $0 } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "bytes": return Format.bytes(value)
        case "bytes/s": return Format.bytes(value) + "/s"
        case "level": return [1: "正常", 2: "偏高", 4: "严重"][Int(value)] ?? "未知"
        default: return String(format: "%.1f", value) + " " + unit
        }
    }
    private func battery(now: Date) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("电池与提醒").font(.headline)
                if let value = store.latest.batterySnapshot {
                    HStack { Text("电池状态"); Spacer(); Text(flag(value.present, now: now, yes: "检测到电池", no: "未发现内置电池")) }.font(.callout)
                    metricRow("电量", reading: value.percent, now: now)
                    HStack { Text("供电状态"); Spacer(); Text(flag(value.externalPower, now: now, yes: "外接电源", no: "电池供电") + " · " + flag(value.charging, now: now, yes: "正在充电", no: "未充电")) }.font(.callout)
                    Text(value.externalPower.source + " · " + value.externalPower.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    metricRow("健康百分比", reading: value.healthPercent, now: now)
                    HStack { Text("系统健康状态"); Spacer(); Text(value.healthCondition.value ?? "不可用"); if value.healthCondition.value != nil && !value.healthCondition.isFresh(at: now) { Text("过期").foregroundStyle(.orange) } }.font(.callout)
                    Text(value.healthCondition.source + " · " + value.healthCondition.timestamp.formatted(date: .omitted, time: .standard) + (value.healthCondition.availabilityReason.map { " · " + $0 } ?? "")).font(.caption2).foregroundStyle(.secondary)
                    HStack { Text("循环次数"); Spacer(); Text(value.cycles.value.map(String.init) ?? "不可用"); if value.cycles.value != nil && !value.cycles.isFresh(at: now) { Text("过期").foregroundStyle(.orange) } }.font(.callout)
                    Text(value.cycles.source + " · " + value.cycles.timestamp.formatted(date: .omitted, time: .standard) + (value.cycles.availabilityReason.map { " · " + $0 } ?? "")).font(.caption2).foregroundStyle(.secondary)
                    metricRow("电池温度", reading: value.temperature, now: now)
                    metricRow("预计充满时间", reading: value.minutesToFull, now: now)
                    metricRow("预计用尽时间", reading: value.minutesToEmpty, now: now)
                } else { Text("尚未收到电池采样；没有电池或缺失字段不会填造零值。").foregroundStyle(.secondary) }
                Divider()
                Toggle("启用电池阈值提醒", isOn: Binding(get: { maintenance.preferences.batteryRule.enabled }, set: { enabled in maintenance.update { $0.batteryRule.enabled = enabled } })).disabled(blocked)
                HStack {
                    Stepper("低电量 \(Int(maintenance.preferences.batteryRule.lowPercent))%", value: batteryBinding(\.lowPercent), in: 5...50, step: 5)
                    Stepper("高电量 \(Int(maintenance.preferences.batteryRule.highPercent))%", value: batteryBinding(\.highPercent), in: 55...100, step: 5)
                }.disabled(blocked)
                HStack {
                    Stepper("温度提醒 \(Int(maintenance.preferences.batteryRule.highTemperature))°C", value: batteryBinding(\.highTemperature), in: 30...70, step: 1)
                    Spacer()
                    Button("允许系统通知") { maintenance.requestNotificationAccess() }.disabled(blocked)
                }
                Text("仅通知，不改变充电。电池温度缺失或过期时不触发温度提醒。").font(.caption).foregroundStyle(.secondary)
                if BatteryCapability.systemChargeLimitAvailable, store.latest.batterySnapshot?.present.value == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("此系统版本提供原生充电上限设置，可由你在系统设置中选择。本应用不读取或更改该设定，未确认硬件控制生效。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("打开系统电池设置…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!) }
                            Link("Apple 充电上限说明", destination: URL(string: "https://support.apple.com/en-us/102338")!)
                        }.font(.caption)
                    }
                }
                ForEach(Array(maintenance.batteryNotices.enumerated()), id: \.offset) { _, notice in Text(notice.title + "：" + notice.detail).font(.caption) }
                DisclosureGroup("充电控制能力与依据") {
                    ForEach(BatteryCapability.current) { value in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(value.title); Spacer(); Text(value.capability.rawValue).foregroundStyle(.secondary) }
                            Text(value.detail).font(.caption).foregroundStyle(.secondary)
                            Link("官方依据", destination: URL(string: value.evidenceURL)!).font(.caption)
                        }.padding(.vertical, 5)
                    }
                }
            }.padding(8)
        }
    }
    private func flag(_ reading: MetricReading<Bool>, now: Date, yes: String, no: String) -> String {
        guard let value = reading.value else { return "未知" }
        return (value ? yes : no) + (reading.isFresh(at: now) ? "" : "（过期）")
    }
    private func batteryBinding(_ key: WritableKeyPath<BatteryRule, Double>) -> Binding<Double> {
        Binding(get: { maintenance.preferences.batteryRule[keyPath: key] }, set: { value in maintenance.update { $0.batteryRule[keyPath: key] = value } })
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
                Toggle("主动启用自动退出", isOn: Binding(get: { maintenance.preferences.appExitEnabled }, set: { value in maintenance.update { $0.appExitEnabled = value } })).disabled(blocked)
                Toggle("暂停所有退出规则", isOn: Binding(get: { maintenance.preferences.appExitPaused }, set: { value in maintenance.update { $0.appExitPaused = value } })).disabled(blocked)
                Text("默认停用；只有逐个启用的应用才参与。前台、未保存、保存状态未知、睡眠及受保护应用会跳过。保留原应用的保存提示，不强退，也不承诺释放多少内存。").font(.caption).foregroundStyle(.secondary)
                if !AXIsProcessTrusted() {
                    HStack {
                        Text("辅助功能权限未获准，无法确认保存状态；规则会跳过。").font(.caption)
                        Button("打开权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                    }
                }
                if maintenance.preferences.rules.isEmpty { Text("尚无规则。添加应用后仍需逐项启用。").foregroundStyle(.secondary) }
                ForEach(maintenance.preferences.rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(rule.name, isOn: ruleBinding(rule, \.enabled))
                            Spacer()
                            Button("移除") { maintenance.update { $0.rules.removeAll { $0.id == rule.id } } }
                        }
                        Text(rule.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Picker("条件", selection: ruleBinding(rule, \.trigger)) { ForEach(AppExitTrigger.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 240)
                            Stepper("后台至少 \(Int(rule.minutes)) 分钟", value: ruleBinding(rule, \.minutes), in: 1...1440, step: 1)
                        }
                        if rule.trigger == .memory {
                            Stepper("内存阈值 \(Format.bytes(Double(rule.memoryBytes)))", value: ruleBinding(rule, \.memoryBytes), in: 16_777_216...137_438_953_472, step: 268_435_456)
                        }
                        HStack {
                            Stepper("冷却 \(Int(rule.cooldownSeconds / 60)) 分钟", value: ruleBinding(rule, \.cooldownSeconds), in: 60...86400, step: 60)
                            Toggle("加入保护名单", isOn: Binding(get: { maintenance.preferences.protectedBundleIDs.contains(rule.bundleID) }, set: { enabled in maintenance.update { value in
                                value.protectedBundleIDs.removeAll { $0 == rule.bundleID }; if enabled { value.protectedBundleIDs.append(rule.bundleID) }
                            } }))
                        }
                        Text(maintenance.ruleReasons[rule.id] ?? "启用后从新观察；不累计以前或休眠时间").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)).disabled(blocked)
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
    private func ruleBinding<Value>(_ rule: AppExitRule, _ key: WritableKeyPath<AppExitRule, Value>) -> Binding<Value> {
        Binding(get: { (maintenance.preferences.rules.first { $0.id == rule.id } ?? rule)[keyPath: key] }, set: { value in
            maintenance.update { state in if let index = state.rules.firstIndex(where: { $0.id == rule.id }) { state.rules[index][keyPath: key] = value } }
        })
    }
}

import SwiftUI

struct AppManagementView: View {
    @ObservedObject var manager: AppManagementController
    var dataBusy: Bool
    @State private var search = ""
    @State private var selectedIDs = Set<String>()
    @State private var confirmation = false
    @State private var pendingPlanID = ""
    @State private var pendingIDs = Set<String>()
    @State private var pendingDescription = ""
    private var blocked: Bool { dataBusy || manager.isBusy }
    private var filteredApps: [InstalledApp] {
        manager.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }
    private var selectedItems: [AppRelatedItem] {
        manager.plan?.items.filter { $0.selectable && selectedIDs.contains($0.id) } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用卸载").font(.title2.weight(.semibold))
                    Text("查看关联，逐项选择，再移入废纸篓。业务资料和共享资源保留。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择应用…") { manager.chooseApplication() }.disabled(blocked).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 9) {
                if manager.isBusy { ProgressView().controlSize(.small) }
                Text(manager.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if manager.isBusy { Button("停止") { manager.cancel() }.disabled(dataBusy) }
            }
            if let error = manager.recoveryError {
                Label("恢复记录异常，已停止移动：\(error)", systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("搜索应用名称或标识", text: $search).textFieldStyle(.roundedBorder)
                        Button(manager.apps.isEmpty ? "读取应用列表" : "刷新列表") { manager.loadApps() }.disabled(blocked)
                    }
                    if manager.apps.isEmpty {
                        Text("仅按需读取系统与个人 Applications 目录，也可直接选择应用。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(filteredApps) { app in
                                    Button { manager.review(appURL: URL(fileURLWithPath: app.path)) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: app.protectedReason == nil ? "app" : "lock.shield").font(.title3)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(app.name).font(.body.weight(.medium))
                                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(app.protectedReason == nil ? "查看关联" : "受保护").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(9).contentShape(Rectangle())
                                        .background(manager.plan?.app.path == app.path ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).disabled(blocked)
                                    .accessibilityLabel("\(app.name)，查看关联项目")
                                }
                            }
                        }.frame(maxHeight: 230)
                    }
                }.padding(5)
            }
            if let plan = manager.plan {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.app.name + " · " + plan.app.version).font(.headline)
                                Text(plan.app.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("在 Finder 中显示") { manager.reveal(plan.app.path) }.disabled(blocked)
                        }
                        ForEach(plan.items) { item in
                            Divider()
                            HStack(alignment: .top, spacing: 10) {
                                if item.selectable {
                                    Toggle("选择\(item.category)", isOn: Binding(
                                        get: { selectedIDs.contains(item.id) },
                                        set: { if $0 { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) } }))
                                        .labelsHidden().toggleStyle(.checkbox).disabled(blocked || !plan.complete)
                                } else { Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 16) }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.category).font(.body.weight(.medium))
                                        Spacer()
                                        Text(item.bytes.map(formatBytes) ?? "保留 / 未扫描").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let path = item.path { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    Text(item.reason).font(.callout).foregroundStyle(item.selectable ? Color.primary : .secondary)
                                    Text(item.evidence).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                        ForEach(plan.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        HStack {
                            Text("已选 \(selectedItems.count) 项 · \(formatBytes(selectedItems.reduce(0) { UninstallFileSafety.add($0, $1.bytes ?? 0) }))")
                                .font(.callout).monospacedDigit()
                            Spacer()
                            Button("移入废纸篓…", role: .destructive) { prepareConfirmation(plan) }
                                .disabled(blocked || !plan.complete || selectedItems.isEmpty || manager.recoveryError != nil)
                        }
                    }.padding(7)
                }
            }
            if let report = manager.report, !report.issues.isEmpty {
                GroupBox("未完成项目") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).font(.callout).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            if !manager.history.isEmpty {
                GroupBox("卸载恢复记录") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("待恢复数不保证原文件仍在废纸篓。恢复不会覆盖同位置的新文件。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(manager.history) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.appName).font(.body.weight(.medium))
                                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.itemCount) 项 · \(entry.pendingCount) 项待尝试恢复")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("恢复此批次") { manager.restore(batchID: entry.id) }
                                    .disabled(blocked || entry.pendingCount == 0 || manager.recoveryError != nil)
                            }
                        }
                    }.padding(6)
                }
            }
            Link("Apple：卸载应用与厂商卸载工具说明", destination: URL(string: "https://support.apple.com/zh-cn/102610")!)
                .font(.caption)
        }
        .onChange(of: manager.plan?.id) { _, _ in selectedIDs.removeAll() }
        .alert("将所选项目移入废纸篓？", isPresented: $confirmation) {
            Button("取消", role: .cancel) { pendingIDs.removeAll() }
            Button("确认移入废纸篓", role: .destructive) {
                guard !blocked, manager.plan?.id == pendingPlanID else { return }
                manager.execute(planID: pendingPlanID, selectedIDs: pendingIDs)
                pendingIDs.removeAll(); selectedIDs.removeAll()
            }
        } message: { Text(pendingDescription) }
    }
    private func prepareConfirmation(_ plan: UninstallPlan) {
        pendingPlanID = plan.id
        pendingIDs = Set(selectedItems.map(\.id))
        pendingDescription = "应用：\(plan.app.name)\n\(selectedItems.map { $0.category + "：" + $0.name }.joined(separator: "\n"))\n\n仅移动已勾选的 \(selectedItems.count) 项。资料库、共享容器、钥匙串和文档保留；不清空废纸篓。"
        confirmation = true
    }
    private func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

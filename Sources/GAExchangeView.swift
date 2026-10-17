import SwiftUI

struct GAExchangeView: View {
    @ObservedObject var exchange: GAExchangeController
    var dataBusy: Bool
    @State private var confirmingCleanup = false
    private func actionName(_ value: String) -> String {
        switch value { case "storage.inspect": return "目录占用分析"; case "cleanup.review": return "白名单缓存复核"; default: return "应用卸载复核" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("动作交接").font(.title2.weight(.semibold)); Spacer()
                Button("导入交接包…") { exchange.importPackage() }.disabled(dataBusy || exchange.isBusy || !exchange.writable)
                if exchange.isBusy { ProgressView().controlSize(.small) }
            }
            HStack {
                Text("\(exchange.records.count) / \(GAExchangeController.recordLimit) 条幂等记录 · \(exchange.privateCopyCount) / \(GAExchangeController.privateCopyLimit) 份私有副本")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清理已完成副本…") { confirmingCleanup = true }
                    .disabled(dataBusy || exchange.isBusy || !exchange.writable || !exchange.canCleanCompletedCopies)
            }
            Text("来源标识未经身份认证。外部请求只提供上下文，所有维护动作仍要在搞机灵内复核。结果默认留在本机，发送由你决定。")
                .font(.callout).foregroundStyle(.secondary)
            if let status = exchange.status { Text(status).font(.callout).textSelection(.enabled) }
            if exchange.records.isEmpty { Text("尚未收到交接请求。可从搞操作显式发送，或导入 .gaoaction 包。没有开启本地 HTTP 服务。") }
            else {
                Picker("请求", selection: $exchange.selectedID) {
                    ForEach(exchange.records.reversed()) { record in Text("\(actionName(record.manifest.action)) · \(record.acceptedAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional(record.id)) }
                }
            }
            if let record = exchange.selected {
                VStack(alignment: .leading, spacing: 12) {
                    Text(actionName(record.manifest.action)).font(.headline)
                    if record.manifest.parameters["mode"] == .string("duplicates") {
                        Text("本请求要求读取目录内的文件内容。进入业务仅预填范围；仍须在存储页明确确认内容分析，未授予删除许可。")
                            .font(.callout).foregroundStyle(GLPalette.amber)
                    }
                    Text("声明来源：\(record.manifest.sourceBundleID)").font(.caption).textSelection(.enabled)
                    Text("请求：\(record.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(record.manifest.references, id: \.id) { reference in
                        Text(reference.displayName).font(.headline)
                        Text((try? GaoActionV1.localURL(reference.fileURL).path) ?? "无效引用").font(.caption).textSelection(.enabled)
                    }
                    if record.phase == "interrupted" {
                        Label("上次运行中断，无法确认是否已有副作用。请核对对应业务历史；不会自动重放，也不代表已回滚。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(GLPalette.amber).fixedSize(horizontal: false, vertical: true)
                    } else if record.phase == "executing" {
                        Text(exchange.writable ? "流程正在执行；结果以对应业务的实际记录为准。" : "上次流程结果无法确认，且中断状态未能保存；请核对业务历史，当前不会继续执行。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("状态：\(outcomeName(record.outcome))").foregroundStyle(.secondary)
                    }
                    if let reason = record.provenance["reason"]?.text { Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if record.incomingCopyRemoved == true { Text("已清理完成请求的输入副本，幂等记录与结果仍保留。可重新生成结果包。") .font(.caption).foregroundStyle(.secondary) }
                    if ["received", "approved", "reviewing"].contains(record.phase) {
                        HStack {
                            if !record.manifest.references.isEmpty { Button("重新选择并核对原对象…") { exchange.chooseReference(record.id) } }
                            Button("复核并进入业务") { exchange.approve(record.id) }.buttonStyle(.borderedProminent)
                        }.disabled(dataBusy || exchange.isBusy || !exchange.writable)
                    } else if record.phase != "finished" {
                        Button("查看本 App 业务复核") { exchange.showBusiness(record.id) }
                    }
                    HStack {
                        Button("发送结果给原应用") { exchange.sendResult(record.id) }
                        Button("导出结果包…") { exchange.exportResult(record.id) }
                        Button("在 Finder 显示结果") { exchange.revealResult(record.id) }
                    }.disabled(dataBusy || exchange.isBusy || !exchange.writable)
                    if ["received", "approved", "reviewing"].contains(record.phase) { Button("结束复核，不再执行") { exchange.cancelReview(record.id) }.disabled(dataBusy || exchange.isBusy || !exchange.writable) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(GLPalette.card, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("仅清理已完成请求的本 App 私有包；未完成、部分、失败及中断副本保留。每个请求最多生成 64 份结果，清理副本不会删除幂等记录或重置 256 条请求额度。达到上限后停止新增，不自动丢弃资料。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("清理已完成请求的私有副本？", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            Button("清理已完成副本", role: .destructive) { exchange.cleanCompletedCopies() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只清理已核验的搞机灵交接副本，不触及原文件、业务恢复记录或对方应用的包。幂等记录和结果摘要保留；部分、失败、中断或尚未完成的请求不清理。")
        }
    }
    private func outcomeName(_ value: String) -> String {
        ["pending": "等待复核或执行结果", "completed": "已完成", "partial": "部分完成", "cancelled": "已取消", "failed": "未完成", "unsupported": "不支持此动作"][value] ?? "状态未知"
    }
}

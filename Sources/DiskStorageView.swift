import SwiftUI

struct DiskStorageView: View {
    @ObservedObject var controller: DiskStorageController
    var dataBusy: Bool
    @State private var query = ""
    @State private var directoryID: String?
    @State private var showAllRecords = false
    @State private var rowLimit = 100
    private var blocked: Bool { dataBusy || controller.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let status = controller.status {
                HStack(spacing: 9) {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "info.circle") }
                    Text(status).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if controller.isBusy { Button("停止") { controller.cancel() } }
                }.font(.system(size: 12)).padding(13)
                    .background(GLPalette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            volumesCard
            imageCard
            if let report = controller.image { imageResults(report) }
        }
        .onChange(of: controller.image?.id) { _, _ in
            directoryID = nil; query = ""; showAllRecords = false; rowLimit = 100
        }
    }

    private var volumesCard: some View {
        GLCard {
            HStack {
                GLSectionTitle(title: "本机内置卷", detail: "已挂载卷的元信息，不遍历文件内容")
                Spacer()
                Button("读取卷信息", systemImage: "arrow.clockwise") { controller.refreshVolumes() }.disabled(blocked)
                Button("导出", systemImage: "square.and.arrow.up") { controller.exportVolumeReport() }
                    .disabled(blocked || controller.volumes == nil)
            }
            if let snapshot = controller.volumes {
                HStack {
                    Text(snapshot.capturedAt, format: .dateTime.month().day().hour().minute().second())
                    Spacer()
                    GLPill(text: snapshot.complete ? "本次查询已返回" : "仅已读取部分", color: snapshot.complete ? GLPalette.blue : GLPalette.amber)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if snapshot.volumes.isEmpty {
                    Text("本次没有可列出的已确认内置卷。未知或排除的范围见说明，不按零容量计算。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(snapshot.volumes) { volume in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: "internaldrive")
                            Text(volume.name ?? "卷名称不可用").fontWeight(.medium)
                            Spacer()
                            Text(volume.isReadOnly.map { $0 ? "只读" : "系统报告可写" } ?? "读写标记不可用")
                                .foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                        Text(volume.mountPath).font(.system(size: 11)).textSelection(.enabled).foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            Text("格式：\(volume.formatDescription ?? "不可用")")
                            Text("总容量：\(bytes(volume.totalBytes))")
                            Text("可用：\(bytes(volume.availableBytes))")
                        }.font(.system(size: 11)).monospacedDigit()
                        if let uuid = volume.uuid { Text("卷标识：\(uuid)").font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                        if !volume.capabilities.isEmpty {
                            Text(volume.capabilities.map { "\($0.name)：\($0.supported.map { $0 ? "是" : "否" } ?? "未知")" }.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if !volume.unavailableFields.isEmpty {
                            Text("不可用：" + volume.unavailableFields.joined(separator: "、"))
                                .font(.system(size: 10)).foregroundStyle(GLPalette.amber)
                        }
                    }.padding(12).background(GLPalette.canvas, in: RoundedRectangle(cornerRadius: 9))
                }
                Text("来源：\(snapshot.source)").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(Array(snapshot.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("主动读取后显示真实卷信息。外接、可移除、网络和归属不明的卷不会作为本机内置卷读取容量。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("APFS 卷可能共享同一容器空间；这里不累加各卷容量，也不把可用容量宣传为可清理空间。读写标记不代表本应用具有写入或修复能力。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var imageCard: some View {
        GLCard {
            HStack {
                GLSectionTitle(title: "普通 NTFS 卷镜像", detail: "单独选择、确认内容读取，全程不挂载")
                Spacer()
                Button("选择镜像…", systemImage: "doc.badge.plus") { controller.chooseImage() }
                    .buttonStyle(.borderedProminent).disabled(blocked)
                Button("导出报告", systemImage: "square.and.arrow.up") { controller.exportImageReport() }
                    .disabled(blocked || controller.image == nil)
            }
            Text("解析预算内的文件记录，浏览已核验的父路径，搜索名称与路径；仅支持的普通文件可以另存新副本。不会默认扫描个人目录，不会改写镜像。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let prepared = controller.preparedImage {
                HStack {
                    Text("待确认：\(prepared.lastPathComponent)").font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("确认读取内容…") { controller.confirmPreparedImage() }.disabled(blocked)
                }
            }
            Text("外接盘、驱动、原始设备、挂载、格式化与修复不做（用户取消）。压缩、加密、稀疏、重解析点或其他不支持的数据流不提供提取。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func imageResults(_ report: DiskImageAnalysis) -> some View {
        let current = directoryID.flatMap { id in report.entries.first { $0.id == id } }
        let root = report.entries.first { $0.recordNumber == 5 && $0.pathComponents == [] }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = !search.isEmpty ? report.search(search) : (showAllRecords ? report.entries : report.children(of: current?.id ?? root?.id ?? ""))
        let sorted = rows.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return GLCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.imageName).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                    Text(report.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                GLPill(text: "有界解析 · 非完整目录", color: GLPalette.amber)
            }
            Text("格式 \(report.format) · 镜像 \(unsignedBytes(report.sourceBytes)) · 累计读取 \(unsignedBytes(report.inspectedBytes)) · 检查 \(report.examinedRecordSlots) / 上限 \(report.recordSlotLimit) 个记录槽")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Text("状态：\(report.status == "unsupported" ? "不支持后续解析" : "部分解析")；源文件变化检查\(report.sourceUnchanged ? "通过" : "未通过")。这不是快照一致性、目录索引完整性或卷健康证明。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                TextField("搜索已读取的名称或路径", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索镜像内已读取记录")
                Toggle("全部记录", isOn: $showAllRecords).toggleStyle(.button)
            }
            if search.isEmpty && !showAllRecords {
                HStack {
                    Button("根目录") { directoryID = nil; rowLimit = 100 }.disabled(root == nil || current == nil)
                    if let current {
                        Button("上一级") { directoryID = current.parentID == root?.id ? nil : current.parentID; rowLimit = 100 }
                        Text(current.displayPath).lineLimit(2).textSelection(.enabled)
                    } else { Text(root == nil ? "根记录不在已读取范围，请查看全部记录" : "/") }
                }.font(.system(size: 11))
            }
            Text("当前 \(rows.count) 项；全部已读取 \(report.entries.count) 项，其中 \(report.unresolvedEntries.count) 项父路径未解析。搜索只覆盖本次结果。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if sorted.isEmpty {
                Text(search.isEmpty ? "当前前缀没有可列出的已核验子项，不代表此目录为空。可切换全部记录查看未解析路径。" : "本次已读取范围没有匹配项。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(sorted.prefix(rowLimit))) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc").foregroundStyle(GLPalette.blue)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                            Text(entry.displayPath).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("记录 \(entry.id) · \(entry.pathComponents == nil ? "父路径未解析" : "父路径已核")").font(.system(size: 10)).foregroundStyle(.secondary)
                            if let reason = entry.extractionUnavailableReason, !entry.isDirectory {
                                Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.isDirectory ? "目录" : entry.logicalBytes.map(unsignedBytes) ?? "大小未知")
                            .font(.system(size: 11)).monospacedDigit()
                        if entry.isDirectory && entry.pathComponents != nil {
                            Button("打开目录") { directoryID = entry.id; showAllRecords = false; query = ""; rowLimit = 100 }
                                .disabled(blocked).accessibilityLabel("打开已核路径目录 \(entry.name)")
                        } else if !entry.isDirectory {
                            Button("提取副本…") { controller.extract(entry) }
                                .disabled(blocked || !entry.canExtract).help(entry.extractionUnavailableReason ?? "仅另存新文件，不覆盖原件")
                        }
                    }.padding(.vertical, 11)
                    Divider().opacity(0.4)
                }
                if sorted.count > rowLimit {
                    Button("再显示 100 项") { rowLimit += 100 }.padding(.top, 8)
                }
            }
            DisclosureGroup("解析范围与说明（\(report.warnings.count) 条）") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(report.hashScope)
                    if let hash = report.sourceSHA256 { Text("源 SHA-256：\(hash)").textSelection(.enabled) }
                    ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, text in Text(text) }
                    ForEach(report.features) { feature in Text("\(feature.feature)：\(feature.state) · \(feature.detail)") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12))
        }
    }

    private func bytes(_ n: Int64?) -> String { n.map { Format.bytes(Double($0)) } ?? "不可用" }
    private func unsignedBytes(_ n: UInt64) -> String { Format.bytes(Double(n)) }
}

import SwiftUI

/// Browses the immutable metadata session. No control in this view removes files.
struct DiskMapView: View {
    let session: ScanSession
    let blocked: Bool
    let reveal: (String) -> Void
    let rescan: (ScanNode) -> Void
    @State private var currentID: String?
    @State private var selectedID: String?
    @State private var search = ""
    @State private var kind = "all"
    @State private var order = "allocated"
    @State private var page = 0
    private let pageSize = 50
    private let otherID = "\u{0}remaining"

    private var current: ScanNode? { currentID.flatMap { session.nodes[$0] } }
    private var selected: ScanNode? { selectedID.flatMap { session.nodes[$0] } }
    private var nodes: [ScanNode] {
        session.children(of: currentID).filter { node in
            (search.isEmpty || node.name.localizedStandardContains(search) || node.path.localizedStandardContains(search)) &&
            (kind == "all" || kind == "directory" && node.kind == .directory || kind == "file" && node.kind == .file ||
             kind == "partial" && (!node.complete || !node.skipReasons.isEmpty))
        }.sorted { a, b in
            if order == "name" { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            let left = order == "logical" ? a.logicalBytes : a.allocatedBytes
            let right = order == "logical" ? b.logicalBytes : b.allocatedBytes
            if left != right { return (left ?? -1) > (right ?? -1) }
            return a.path < b.path
        }
    }
    private var weights: [(id: String, bytes: Int64)] {
        let positive = nodes.filter { ($0.allocatedBytes ?? 0) > 0 }.sorted { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }
        var values = positive.prefix(47).map { (id: $0.id, bytes: $0.allocatedBytes!) }
        let remainder = positive.dropFirst(47).reduce(Int64(0)) { sum, node in
            let result = sum.addingReportingOverflow(node.allocatedBytes ?? 0)
            return result.overflow ? Int64.max : result.partialValue
        }
        if remainder > 0 { values.append((otherID, remainder)) }
        return values
    }
    private var pageCount: Int { max(1, (nodes.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var visible: [ScanNode] { Array(nodes.dropFirst(currentPage * pageSize).prefix(pageSize)) }

    var body: some View {
        let displayedNodes = visible
        GLCard {
            HStack {
                GLSectionTitle(title: "磁盘地图", detail: "只读目录树")
                Spacer()
                Text("\(session.nodes.count) 个已记录节点").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            breadcrumbs
            if let current {
                HStack(spacing: 15) {
                    Text("已分配 \(bytes(current.allocatedBytes))")
                    Text("逻辑长度 \(bytes(current.logicalBytes))")
                    Spacer(minLength: 8)
                    if !current.complete { GLPill(text: "部分", color: GLPalette.amber) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if !current.skipReasons.isEmpty {
                    Text(current.skipReasons.joined(separator: "；"))
                        .font(.system(size: 10)).foregroundStyle(GLPalette.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                TextField("搜索本层名称或路径", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索磁盘地图当前目录")
                Picker("类型", selection: $kind) {
                    Text("全部类型").tag("all")
                    Text("目录").tag("directory")
                    Text("文件").tag("file")
                    Text("部分或跳过").tag("partial")
                }.labelsHidden().frame(width: 120).accessibilityLabel("磁盘地图类型筛选")
                Picker("排序", selection: $order) {
                    Text("按已分配空间").tag("allocated")
                    Text("按逻辑长度").tag("logical")
                    Text("按名称").tag("name")
                }.labelsHidden().frame(width: 145).accessibilityLabel("目录排序")
            }.font(.system(size: 11))
            if !weights.isEmpty {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(DiskMapLayout.rectangles(weights, in: CGRect(origin: .zero, size: proxy.size))) { tile in
                            tileView(tile)
                        }
                    }
                }.frame(height: 220).clipped()
            }
            Text("矩形按当前筛选中已确认的分配空间绘制；点击目录进入，文件仅选中查看。零占用、未读取和较小项目仍可在下方列表查看。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if displayedNodes.isEmpty {
                Text(!search.isEmpty || kind != "all" ? "本层没有匹配项目。" : (current?.complete == true ? "此目录没有子项目。" : "本层没有可列出的节点；部分结果不代表目录为空。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                HStack {
                    Text("本层项目")
                    Spacer()
                    Text("逻辑长度").frame(width: 86, alignment: .trailing)
                    Text("已分配空间").frame(width: 86, alignment: .trailing)
                    Color.clear.frame(width: 24, height: 1)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                LazyVStack(spacing: 0) {
                    ForEach(displayedNodes) { node in
                        row(node)
                        if node.id != displayedNodes.last?.id { Divider().opacity(0.4) }
                    }
                }
                HStack {
                    Text("共 \(nodes.count) 项 · 每页 \(pageSize) 项").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("上一页") { page = max(0, currentPage - 1) }.disabled(currentPage == 0)
                    Text("\(currentPage + 1) / \(pageCount)").font(.system(size: 11)).monospacedDigit()
                    Button("下一页") { page = min(pageCount - 1, currentPage + 1) }.disabled(currentPage >= pageCount - 1)
                }.buttonStyle(.borderless)
            }
            if let selected { selectionDetails(selected) }
            HStack(alignment: .top) {
                Text("逻辑长度是文件长度；已分配空间按本地磁盘块估算。硬链接只累计一次，APFS 共享空间不能据此计算可释放量。目录树有节点上限，未读部分不会当作零。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                if let current {
                    Button("重新分析此目录") { rescan(current) }.buttonStyle(.bordered).disabled(blocked || current.directoryIdentity == nil)
                        .help("单独分析当前目录，重新核对路径并生成新结果；不会移动文件。")
                }
            }
        }
        .onAppear { if currentID == nil && session.rootIDs.count == 1 { currentID = session.rootIDs.first } }
        .onChange(of: search) { _, _ in page = 0 }
        .onChange(of: kind) { _, _ in page = 0 }
        .onChange(of: order) { _, _ in page = 0 }
    }
    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button("扫描范围") { navigate(nil) }.buttonStyle(.borderless)
                if let currentID {
                    ForEach(session.breadcrumbs(to: currentID)) { node in
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Button(node.name) { navigate(node.id) }.buttonStyle(.borderless).help(node.path)
                    }
                } else {
                    Text(session.scope).foregroundStyle(.secondary).lineLimit(1).help(session.scope)
                }
            }.font(.system(size: 11)).padding(.vertical, 3)
        }
    }
    private func navigate(_ id: String?) { currentID = id; selectedID = nil; page = 0; search = "" }
    private func activate(_ node: ScanNode) {
        if node.kind == .directory { navigate(node.id) }
        else { selectedID = node.id }
    }
    private func row(_ node: ScanNode) -> some View {
        HStack(spacing: 10) {
            Button { activate(node) } label: {
                HStack(spacing: 7) {
                    Image(systemName: node.kind == .directory ? "folder" : "doc").foregroundStyle(GLPalette.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.name).font(.system(size: 12)).lineLimit(1).help(node.path)
                        if !node.complete || !node.skipReasons.isEmpty {
                            Text(node.skipReasons.first ?? "仅已读取部分").font(.system(size: 9)).foregroundStyle(GLPalette.amber).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if node.kind == .directory { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(node.kind == .directory ? "进入目录" : "查看文件") \(node.name)")
            Text(bytes(node.logicalBytes)).frame(width: 86, alignment: .trailing)
            Text(bytes(node.allocatedBytes)).frame(width: 86, alignment: .trailing)
            Button { reveal(node.path) } label: { Image(systemName: "folder").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示 \(node.name)")
        }.font(.system(size: 10)).monospacedDigit().padding(.vertical, 9)
    }
    private func tileView(_ tile: DiskMapLayout.Tile) -> some View {
        let node = session.nodes[tile.id]
        let isOther = tile.id == otherID
        return Button {
            if let node { activate(node) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if tile.rect.width > 48 && tile.rect.height > 24 {
                    Text(isOther ? "其余项目" : node?.name ?? "").font(.system(size: 11, weight: .medium)).lineLimit(2)
                    if tile.rect.height > 55 {
                        Text(bytes(isOther ? weights.last?.bytes : node?.allocatedBytes)).font(.system(size: 10)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }.padding(7).frame(width: max(0, tile.rect.width - 2), height: max(0, tile.rect.height - 2), alignment: .topLeading)
                .foregroundStyle(.white)
                .background((node?.kind == .directory ? GLPalette.accent : GLPalette.blue).opacity(isOther ? 0.65 : 0.9), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(isOther)
            .help(isOther ? "较小项目合并显示，可在列表逐页查看" : "\(node?.path ?? "")\n已分配 \(bytes(node?.allocatedBytes))")
            .accessibilityLabel(isOther ? "其余较小项目，见下方列表" : "\(node?.name ?? "项目")，已分配 \(bytes(node?.allocatedBytes))")
            .offset(x: tile.rect.minX + 1, y: tile.rect.minY + 1)
    }
    private func selectionDetails(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.path).font(.system(size: 11)).textSelection(.enabled)
            Text("\(node.category) · 逻辑 \(bytes(node.logicalBytes)) · 已分配 \(bytes(node.allocatedBytes))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let device = node.device, let inode = node.inode {
                Text("设备 \(device) · inode \(inode) · 扫描于 \(session.finishedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if !node.skipReasons.isEmpty { Text(node.skipReasons.joined(separator: "；")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(GLPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
    }
    private func bytes(_ value: Int64?) -> String { value.map { Format.bytes(Double($0)) } ?? "未读取" }
}

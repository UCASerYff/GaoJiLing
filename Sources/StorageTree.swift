import Foundation
import CoreGraphics

/// An expected object identity from a local review. The scanner compares it to
/// its own nofollow root FD before enumerating; the path alone is not identity.
struct StorageDirectoryIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    var ownerUID: UInt32? = nil
}

/// In-memory metadata snapshot only. These identities never confer deletion rights.
struct ScanNode: Identifiable, Sendable {
    enum Kind: String, Sendable { case directory, file, symbolicLink, other, unknown }
    let id: String
    let parentID: String?
    let name: String
    let path: String
    let kind: Kind
    let category: String
    let device: Int32?
    let inode: UInt64?
    let ownerUID: UInt32?
    var logicalBytes: Int64?
    var allocatedBytes: Int64?
    var fileCount: Int
    var complete: Bool
    var skipReasons: [String]
    var childIDs: [String]
    var directoryIdentity: StorageDirectoryIdentity? {
        guard kind == .directory, let device, let inode else { return nil }
        return StorageDirectoryIdentity(device: device, inode: inode, ownerUID: ownerUID)
    }
}

struct ScanProgress: Sendable {
    let visitedEntries: Int
    let fileCount: Int
    let directoryCount: Int
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let skippedCount: Int
    let currentPath: String?
    let elapsedSeconds: Double
}

enum StorageScanCompletion: String, Sendable { case completed, partial, cancelled, failed }

struct ScanSession: Identifiable, Sendable {
    let id: UUID
    let scope: String
    let startedAt: Date
    let finishedAt: Date
    let rootIDs: [String]
    let nodes: [String: ScanNode]
    var complete: Bool
    var cancelled: Bool
    let stopReason: String?
    let maximumNodes: Int
    let progress: ScanProgress

    func children(of nodeID: String?) -> [ScanNode] {
        guard let nodeID else { return rootIDs.compactMap { nodes[$0] } }
        return (nodes[nodeID]?.childIDs ?? []).compactMap { nodes[$0] }
    }
    func breadcrumbs(to nodeID: String) -> [ScanNode] {
        var result: [ScanNode] = []
        var next: String? = nodeID
        // A bounded walk also prevents a corrupted parent relationship looping UI.
        for _ in 0..<65 {
            guard let id = next, let node = nodes[id], !result.contains(where: { $0.id == id }) else { break }
            result.append(node); next = node.parentID
        }
        return result.reversed()
    }
}

/// Balanced binary treemap. The caller supplies bounded, positive weights.
/// Rectangles are adjacent and their area is proportional to confirmed bytes.
enum DiskMapLayout {
    struct Tile: Identifiable { let id: String; let rect: CGRect }
    static func rectangles(_ values: [(id: String, bytes: Int64)], in bounds: CGRect) -> [Tile] {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return [] }
        let values = values.filter { $0.bytes > 0 }.prefix(48).map { ($0.id, Double($0.bytes)) }
        var result: [Tile] = []
        func divide(_ items: ArraySlice<(String, Double)>, _ rect: CGRect) {
            guard !items.isEmpty else { return }
            if items.count == 1 { result.append(Tile(id: items.first!.0, rect: rect)); return }
            let total = items.reduce(0.0) { $0 + $1.1 }
            var sum = 0.0, split = items.startIndex + 1
            for index in items.indices.dropLast() {
                sum += items[index].1
                split = index + 1
                if sum >= total / 2 { break }
            }
            let first = items[..<split], second = items[split...]
            let ratio = first.reduce(0.0) { $0 + $1.1 } / total
            if rect.width >= rect.height {
                let length = rect.width * ratio
                divide(first, CGRect(x: rect.minX, y: rect.minY, width: length, height: rect.height))
                divide(second, CGRect(x: rect.minX + length, y: rect.minY, width: rect.width - length, height: rect.height))
            } else {
                let length = rect.height * ratio
                divide(first, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: length))
                divide(second, CGRect(x: rect.minX, y: rect.minY + length, width: rect.width, height: rect.height - length))
            }
        }
        divide(values[...], bounds)
        return result
    }
}

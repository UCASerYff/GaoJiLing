import Foundation

enum SessionComparisonError: LocalizedError {
    case invalidSelection, missingSession, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "请选择两条不同的已完成任务。"
        case .missingSession: return "有任务已不存在或尚未结束，请重新选择。"
        case .unavailable: return "暂时无法读取任务资料，请重试。"
        }
    }
}

enum SessionComparisonTrendSource: Equatable { case session, history }

struct SessionComparisonPoint: Codable, Equatable, Identifiable {
    var id: TimeInterval { elapsed }
    let elapsed: TimeInterval
    let cpu: Double?
    let memory: Double?

    init?(sample: MetricsSample, start: Date) {
        let offset = sample.timestamp.timeIntervalSince(start)
        guard offset.isFinite, offset >= 0 else { return nil }
        let cpu = Self.usage(sample.cpuPercent)
        let memory = Self.usedMemory(sample)
        guard cpu != nil || memory != nil else { return nil }
        self.init(elapsed: offset, cpu: cpu, memory: memory)
    }

    init(elapsed: TimeInterval, cpu: Double?, memory: Double?) {
        self.elapsed = elapsed
        self.cpu = cpu
        self.memory = memory
    }

    static func usage(_ value: Double?) -> Double? {
        value.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    static func bytes(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }

    private static func usedMemory(_ sample: MetricsSample) -> Double? {
        guard sample.memoryTotal.isFinite, sample.memoryTotal > 0,
              sample.memoryUsed <= sample.memoryTotal else { return nil }
        if let reading = sample.readings?["memory"], !reading.isFresh(at: sample.timestamp, maximumAge: 0) { return nil }
        return bytes(sample.memoryUsed)
    }
}

struct SessionComparisonProcess: Codable, Equatable {
    let name: String
    let cpu: Double
    let memory: Double?
}

struct SessionComparisonProcessSnapshot: Codable, Equatable {
    let timestamp: Date
    let systemCPU: Double
    let rows: [SessionComparisonProcess]
}

struct SessionComparisonRun {
    let session: MonitorSession
    let duration: TimeInterval
    let averageCPU: Double?
    let peakCPU: Double?
    let peakMemory: Double?
    let sampleStart: Date?
    let sampleEnd: Date?
    let sampleCount: Int?
    let trend: [SessionComparisonPoint]
    let trendSource: SessionComparisonTrendSource
    let trendGap: TimeInterval
    let processSnapshot: SessionComparisonProcessSnapshot?

    init(session: MonitorSession, end: Date, details: SessionComparisonDetails?, history: [SessionComparisonPoint]) {
        self.session = session
        duration = max(0, end.timeIntervalSince(session.start))
        averageCPU = session.sampleCount > 0 ? SessionComparisonPoint.usage(session.averageCPU) : nil
        peakCPU = session.sampleCount > 0 ? SessionComparisonPoint.usage(session.peakCPU) : nil
        let memoryAvailable = details.map { $0.memoryCount > 0 } ?? (session.peakMemory > 0)
        peakMemory = memoryAvailable ? SessionComparisonPoint.bytes(session.peakMemory) : nil
        sampleCount = details?.sampleCount
        trend = details?.points ?? history
        trendSource = details == nil ? .history : .session
        let first = details?.first ?? history.first?.elapsed
        let last = details?.last ?? history.last?.elapsed
        sampleStart = first.map { session.start.addingTimeInterval($0) }
        sampleEnd = last.map { session.start.addingTimeInterval($0) }
        let latestPossible = min(end, session.lastObserved ?? end)
        let width = details?.bucket ?? SessionComparisonDetails.bucketWidth(for: latestPossible.timeIntervalSince(session.start))
        trendGap = max(details == nil ? 65 : 15, width * 1.5)
        processSnapshot = details?.processSnapshot
    }
}

struct SessionComparisonDetails: Codable, Equatable {
    static let taskLimit = 48
    static let pointLimit = 120
    static let processLimit = 8
    static let backupPrefix = "GaoJiLing.Mac.SessionCompare."
    private static let minimumBucket: TimeInterval = 10
    private static let processNameBytes = 128

    private(set) var sampleCount = 0
    private(set) var memoryCount = 0
    private(set) var bucket = SessionComparisonDetails.minimumBucket
    private(set) var first: TimeInterval?
    private(set) var last: TimeInterval?
    private(set) var points: [SessionComparisonPoint] = []
    private(set) var processSnapshot: SessionComparisonProcessSnapshot?

    init() {}

    static func bucketWidth(for elapsed: TimeInterval) -> TimeInterval {
        var width = minimumBucket
        while elapsed / width >= Double(pointLimit) { width *= 2 }
        return width
    }

    @discardableResult
    mutating func observe(_ sample: MetricsSample, start: Date, processBaseline: Date?, processFloor: Date) -> SessionComparisonPoint? {
        guard let point = SessionComparisonPoint(sample: sample, start: start),
              last.map({ point.elapsed > $0 }) ?? true else { return nil }
        if first == nil { first = point.elapsed }
        last = point.elapsed
        sampleCount += 1
        if point.memory != nil { memoryCount += 1 }

        let width = Self.bucketWidth(for: point.elapsed)
        if width != bucket {
            bucket = width
            let representatives = Dictionary(points.map { (Int($0.elapsed / width), $0) }, uniquingKeysWith: { _, newer in newer })
            points = representatives.values.sorted { $0.elapsed < $1.elapsed }
        }
        if let previous = points.last, Int(previous.elapsed / bucket) == Int(point.elapsed / bucket) {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }

        // Cached rankings have no baseline for this sample. The measured CPU interval must be
        // entirely within this recording and the current uninterrupted sampling segment.
        if let processBaseline, processBaseline >= max(start, processFloor), processBaseline < sample.timestamp,
           let cpu = point.cpu, processSnapshot.map({ cpu > $0.systemCPU }) ?? true {
            let rows = sample.processes.lazy.filter { process in
                process.observedAt == sample.timestamp && process.cpuAvailable == true && process.availabilityReason == nil
                    && SessionComparisonPoint.usage(process.cpuPercent) != nil
                    && !(process.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || process.name.contains("\0"))
            }.sorted {
                if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                let left = SessionComparisonPoint.bytes($0.memoryBytes) ?? 0
                let right = SessionComparisonPoint.bytes($1.memoryBytes) ?? 0
                if left != right { return left > right }
                return $0.name < $1.name
            }.lazy.compactMap { process -> SessionComparisonProcess? in
                let cleaned = process.name.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = String(decoding: cleaned.utf8.prefix(Self.processNameBytes), as: UTF8.self)
                guard !name.isEmpty else { return nil }
                return SessionComparisonProcess(name: name, cpu: process.cpuPercent, memory: SessionComparisonPoint.bytes(process.memoryBytes))
            }.prefix(Self.processLimit)
            let top = Array(rows)
            if !top.isEmpty {
                processSnapshot = SessionComparisonProcessSnapshot(timestamp: sample.timestamp, systemCPU: cpu, rows: top)
            }
        }
        return point
    }

    func isValid(duration: TimeInterval, start: Date) -> Bool {
        guard duration.isFinite, duration >= 0, sampleCount >= 0, (0...sampleCount).contains(memoryCount),
              points.count <= min(sampleCount, Self.pointLimit), (sampleCount == 0) == points.isEmpty else { return false }
        guard let first, let last else {
            return first == nil && last == nil && points.isEmpty && bucket == Self.minimumBucket && processSnapshot == nil
        }
        guard !points.isEmpty, (0...duration).contains(first), (first...duration).contains(last),
              bucket == Self.bucketWidth(for: last), points.last?.elapsed == last else { return false }
        var previousBucket = -1
        for point in points {
            guard (first...last).contains(point.elapsed), point.cpu != nil || point.memory != nil,
                  point.cpu == nil || SessionComparisonPoint.usage(point.cpu) != nil,
                  point.memory.map({ SessionComparisonPoint.bytes($0) != nil }) ?? true else { return false }
            let index = Int(point.elapsed / bucket)
            guard index > previousBucket else { return false }
            previousBucket = index
        }
        if let processSnapshot {
            let offset = processSnapshot.timestamp.timeIntervalSince(start)
            guard (first...last).contains(offset), SessionComparisonPoint.usage(processSnapshot.systemCPU) != nil,
                  (1...Self.processLimit).contains(processSnapshot.rows.count) else { return false }
            for row in processSnapshot.rows {
                guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      row.name.rangeOfCharacter(from: .controlCharacters) == nil,
                      row.name.utf8.count <= Self.processNameBytes + 2, SessionComparisonPoint.usage(row.cpu) != nil,
                      row.memory.map({ SessionComparisonPoint.bytes($0) != nil }) ?? true else { return false }
            }
        }
        return true
    }
}

struct ArchivedSessionComparison: Codable {
    let id: UUID
    let start: Date
    let end: Date
    let details: SessionComparisonDetails

    func matches(_ session: MonitorSession) -> Bool {
        id == session.id && start == session.start && end == session.end && session.sampleCount <= details.sampleCount
            && details.isValid(duration: end.timeIntervalSince(start), start: start)
    }
}

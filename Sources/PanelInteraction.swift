import Foundation

/// Every opening path gets a short chance to move into the panel. Afterwards,
/// only pointer presence or an ongoing mouse gesture keeps it expanded.
struct PanelAutoCollapse {
    static let openingGrace: TimeInterval = 1.8
    static let exitDelay: TimeInterval = 0.45
    private var openedAt: TimeInterval?
    private var outsideSince: TimeInterval?

    mutating func opened(at time: TimeInterval) {
        openedAt = time
        outsideSince = nil
    }

    mutating func closed() {
        openedAt = nil
        outsideSince = nil
    }

    mutating func shouldCollapse(at time: TimeInterval, pointerInside: Bool, mousePressed: Bool) -> Bool {
        guard let openedAt else { return false }
        if pointerInside || mousePressed {
            outsideSince = nil
            return false
        }
        guard time - openedAt >= Self.openingGrace else { return false }
        guard let outsideSince else {
            self.outsideSince = time
            return false
        }
        return time - outsideSince >= Self.exitDelay
    }
}

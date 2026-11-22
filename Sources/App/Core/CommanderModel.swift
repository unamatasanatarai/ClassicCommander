import Foundation

/// The two panels and which one has focus.
public final class CommanderModel {
    public enum Side: Equatable {
        case left
        case right

        public var other: Side { self == .left ? .right : .left }
    }

    public let left: PanelModel
    public let right: PanelModel
    public private(set) var activeSide: Side = .left

    public init(left: PanelModel, right: PanelModel) {
        self.left = left
        self.right = right
    }

    public var active: PanelModel { panel(activeSide) }
    public var inactive: PanelModel { panel(activeSide.other) }

    public func panel(_ side: Side) -> PanelModel {
        side == .left ? left : right
    }

    public func toggleActive() {
        activeSide = activeSide.other
    }

    public func activate(_ side: Side) {
        activeSide = side
    }
}

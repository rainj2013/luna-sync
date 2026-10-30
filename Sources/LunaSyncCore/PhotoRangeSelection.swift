import Foundation

/// Selection state shared by endpoint gestures and the live picker count.
public struct PhotoRangeSelection {
    public private(set) var selected: Set<String>
    public private(set) var anchor: String?
    public init(selected: Set<String> = []) { self.selected = selected }

    @discardableResult
    public mutating func select(_ identifier: String, orderedIdentifiers: [String]) -> Set<String> {
        selected.insert(identifier)
        if let anchor,
           let first = orderedIdentifiers.firstIndex(of: anchor),
           let last = orderedIdentifiers.firstIndex(of: identifier) {
            selected.formUnion(orderedIdentifiers[min(first, last)...max(first, last)])
            self.anchor = nil
        } else { anchor = identifier }
        return selected
    }

    public mutating func deselect(_ identifier: String) {
        selected.remove(identifier)
        if anchor == identifier { anchor = nil }
    }
}

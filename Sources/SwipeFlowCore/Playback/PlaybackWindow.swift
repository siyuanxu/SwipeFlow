public struct PlaybackWindowPolicy: Hashable, Sendable {
    public let previousCount: Int
    public let nextCount: Int

    public init(previousCount: Int = 1, nextCount: Int = 5) {
        self.previousCount = max(0, previousCount)
        self.nextCount = max(0, nextCount)
    }

    public var capacity: Int {
        previousCount + 1 + nextCount
    }

    public func indexes(focusedIndex: Int, itemCount: Int) -> [Int] {
        guard itemCount > 0, focusedIndex >= 0, focusedIndex < itemCount else {
            return []
        }

        let lowerBound = max(0, focusedIndex - previousCount)
        let upperBound = min(itemCount - 1, focusedIndex + nextCount)
        return Array(lowerBound...upperBound)
    }

    /// Current first, then upcoming items, then previous items. This makes a newly
    /// focused item playable before background preparation starts.
    public func loadingOrder(focusedIndex: Int, itemCount: Int) -> [Int] {
        let window = Set(indexes(focusedIndex: focusedIndex, itemCount: itemCount))
        guard window.contains(focusedIndex) else { return [] }

        var result = [focusedIndex]
        if nextCount > 0 {
            for offset in 1...nextCount where window.contains(focusedIndex + offset) {
                result.append(focusedIndex + offset)
            }
        }
        if previousCount > 0 {
            for offset in 1...previousCount where window.contains(focusedIndex - offset) {
                result.append(focusedIndex - offset)
            }
        }
        return result
    }
}

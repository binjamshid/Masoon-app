/// Memorization order (D-005 as normalized in ENGINE_SEMANTICS §2).
///
/// The order is a permutation of ayahs: `orderToGlobal[pos]` maps an order
/// position to the global 0-based ayah id, and `globalToOrder` the inverse
/// (-1 when the ayah is not in the order domain, e.g. custom lists).
///
/// - `mushaf_forward`: canonical ayah order.
/// - `juz_amma_backward`: juz blocks descending (30, 29, 28, …), surahs
///   descending inside each juz block, ayahs ascending within a surah.
/// - `custom_list`: explicit ordered `CanonicalRange[]`, expanded in sequence.
///
/// Generic over `ContentIndex` (Batch 3 Stage 2): `Index` is resolved at the
/// call site (`QuranIndex` today; `PoemIndex` proves a second corpus can walk
/// the same order-building logic). `.juzAmmaBackward`'s name stays Qur'an-
/// flavored — it is curriculum POLICY vocabulary (`MemorizationOrderKind`,
/// PlanPolicy.swift), not part of this file's generalization.

public struct MemorizationOrder<Index: ContentIndex>: Sendable {
    public let orderToGlobal: [Int]
    public let globalToOrder: [Int]   // -1 = not in domain
    public var count: Int { orderToGlobal.count }

    public enum OrderError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            if case .invalid(let m) = self { return "memorization order error: \(m)" }
            return "memorization order error"
        }
    }

    public init(kind: MemorizationOrderKind, index: Index) throws {
        var sequence: [Int] = []
        switch kind {
        case .mushafForward:
            sequence = Array(0..<index.totalUnits)

        case .juzAmmaBackward:
            sequence.reserveCapacity(index.totalUnits)
            for juz in stride(from: index.boundaryCount, through: 1, by: -1) {
                guard let block = index.boundaryGlobalRange(juz) else {
                    throw OrderError.invalid("juz \(juz) missing from index")
                }
                // Group the block's ayahs into per-surah runs (within a juz a
                // surah appears as one contiguous run), then order runs by
                // surah descending, ayahs ascending within each run.
                var runs: [(surah: Int, globals: [Int])] = []
                for g in block {
                    let s = index.workOfGlobal(g)
                    if runs.last?.surah == s {
                        runs[runs.count - 1].globals.append(g)
                    } else {
                        runs.append((s, [g]))
                    }
                }
                for run in runs.sorted(by: { $0.surah > $1.surah }) {
                    sequence.append(contentsOf: run.globals)
                }
            }

        case .customList(let list):
            var seen = Set<Int>()
            for range in list {
                guard let globals = index.globalRange(of: range) else {
                    throw OrderError.invalid("custom range \(range) is out of bounds")
                }
                for g in globals {
                    guard seen.insert(g).inserted else {
                        throw OrderError.invalid("custom list repeats ayah \(index.position(ofGlobal: g))")
                    }
                    sequence.append(g)
                }
            }
        }

        self.orderToGlobal = sequence
        var inverse = [Int](repeating: -1, count: index.totalUnits)
        for (pos, g) in sequence.enumerated() { inverse[g] = pos }
        self.globalToOrder = inverse
    }

    public func orderPosition(ofGlobal g: Int) -> Int? {
        guard g >= 0, g < globalToOrder.count, globalToOrder[g] >= 0 else { return nil }
        return globalToOrder[g]
    }
}

/// Sorted, disjoint, coalesced spans over order positions. The engine's
/// working representation for all content sets (ledgers, pools, unions).
public struct OrderSpanSet: Hashable, Sendable {
    /// Half-open [start, end) order-position spans, sorted, disjoint, non-adjacent.
    public var spans: [(start: Int, end: Int)] {
        storage.map { (start: $0.start, end: $0.end) }
    }

    private struct Span: Hashable, Sendable {
        var start: Int
        var end: Int
    }

    private var storage: [Span] = []

    public init() {}

    public init(span: Range<Int>) {
        if !span.isEmpty { storage = [Span(start: span.lowerBound, end: span.upperBound)] }
    }

    public var isEmpty: Bool { storage.isEmpty }

    public var positionCount: Int { storage.reduce(0) { $0 + ($1.end - $1.start) } }

    public var first: Int? { storage.first?.start }

    public mutating func insert(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        var newSpan = Span(start: range.lowerBound, end: range.upperBound)
        var result: [Span] = []
        var placed = false
        for span in storage {
            if span.end < newSpan.start {
                result.append(span)
            } else if span.start > newSpan.end {
                if !placed { result.append(newSpan); placed = true }
                result.append(span)
            } else {
                newSpan.start = min(newSpan.start, span.start)
                newSpan.end = max(newSpan.end, span.end)
            }
        }
        if !placed { result.append(newSpan) }
        storage = result
    }

    public mutating func formUnion(_ other: OrderSpanSet) {
        for span in other.storage { insert(span.start..<span.end) }
    }

    public func union(_ other: OrderSpanSet) -> OrderSpanSet {
        var copy = self
        copy.formUnion(other)
        return copy
    }

    public func subtracting(_ other: OrderSpanSet) -> OrderSpanSet {
        var result = OrderSpanSet()
        for span in storage {
            var pieces = [(span.start, span.end)]
            for cut in other.storage {
                var next: [(Int, Int)] = []
                for (s, e) in pieces {
                    if cut.end <= s || cut.start >= e {
                        next.append((s, e))
                    } else {
                        if cut.start > s { next.append((s, cut.start)) }
                        if cut.end < e { next.append((cut.end, e)) }
                    }
                }
                pieces = next
            }
            for (s, e) in pieces where s < e { result.insert(s..<e) }
        }
        return result
    }

    public func contains(_ position: Int) -> Bool {
        for span in storage {
            if position < span.start { return false }
            if position < span.end { return true }
        }
        return false
    }

    /// All positions in ascending order.
    public var positions: [Int] {
        var out: [Int] = []
        out.reserveCapacity(positionCount)
        for span in storage { out.append(contentsOf: span.start..<span.end) }
        return out
    }

    /// First position >= `position`, or nil.
    public func firstPosition(atOrAfter position: Int) -> Int? {
        for span in storage {
            if position < span.start { return span.start }
            if position < span.end { return position }
        }
        return nil
    }

    public func sum(_ weight: (Int) -> Int64) -> Int64 {
        var total: Int64 = 0
        for span in storage {
            for p in span.start..<span.end { total += weight(p) }
        }
        return total
    }
}

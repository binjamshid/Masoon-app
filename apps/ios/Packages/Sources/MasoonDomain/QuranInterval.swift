/// A validated inclusive Qur'an interval whose endpoints may cross surahs.
///
/// `CanonicalRange` deliberately remains single-surah because it is a
/// persisted engine/content primitive. Listening and sharing need a distinct
/// value: two canonical positions, validated against the authoritative index,
/// which can be projected into ordered single-surah ranges only at a consumer
/// boundary.
public struct QuranInterval: Hashable, Sendable, CustomStringConvertible {
    public let start: CanonicalPosition
    public let end: CanonicalPosition
    public let count: Int

    public init?(
        start: CanonicalPosition,
        end: CanonicalPosition,
        index: any ContentIndex
    ) {
        guard let startGlobal = index.globalIndex(of: start),
              let endGlobal = index.globalIndex(of: end),
              startGlobal <= endGlobal
        else { return nil }
        self.start = start
        self.end = end
        self.count = endGlobal - startGlobal + 1
    }

    /// Ordered, inclusive single-surah segments. Returning no ranges means
    /// the supplied index does not contain the interval's original canonical
    /// endpoints; callers must not guess around an edition/index mismatch.
    public func canonicalRanges(in index: any ContentIndex) -> [CanonicalRange] {
        guard let startGlobal = index.globalIndex(of: start),
              let endGlobal = index.globalIndex(of: end),
              startGlobal <= endGlobal,
              endGlobal - startGlobal + 1 == count
        else { return [] }

        var ranges: [CanonicalRange] = []
        var rangeWork = index.workOfGlobal(startGlobal)
        var rangeStart = index.unitOfGlobal(startGlobal)
        var previousUnit = rangeStart

        if startGlobal < endGlobal {
            for global in (startGlobal + 1)...endGlobal {
                let work = index.workOfGlobal(global)
                let unit = index.unitOfGlobal(global)
                if work != rangeWork {
                    if let range = CanonicalRange(
                        work: rangeWork, unitStart: rangeStart, unitEnd: previousUnit)
                    {
                        ranges.append(range)
                    }
                    rangeWork = work
                    rangeStart = unit
                }
                previousUnit = unit
            }
        }

        if let range = CanonicalRange(
            work: rangeWork, unitStart: rangeStart, unitEnd: previousUnit)
        {
            ranges.append(range)
        }
        return ranges
    }

    /// Every coordinate in canonical order, used by preview/share formatters
    /// that must source each ayah independently rather than concatenate a
    /// fabricated cross-surah range.
    public func positions(in index: any ContentIndex) -> [CanonicalPosition] {
        guard let startGlobal = index.globalIndex(of: start),
              let endGlobal = index.globalIndex(of: end),
              startGlobal <= endGlobal,
              endGlobal - startGlobal + 1 == count
        else { return [] }
        return (startGlobal...endGlobal).map(index.position(ofGlobal:))
    }

    public var streamForm: String { "\(start)–\(end)" }
    public var description: String { streamForm }
}

/// Corpus-agnostic content index protocol (Batch 3 Stage 2).
///
/// `QuranIndex` was the engine's only content index; the curriculum engine
/// (scheduling, selection, forecasting — `MasoonCurriculum`) hardcoded it
/// directly. This protocol extracts exactly the surface the engine actually
/// uses, so the SAME engine can run over a second, structurally different
/// corpus (a poem/manẓūma collection — `PoemIndex`) without the engine ever
/// knowing which one it holds.
///
/// Vocabulary mapping (Qur'an term -> generic term):
///   - surah      -> work            (a titled subdivision of the corpus)
///   - ayah       -> unit            (the atomic memorization element)
///   - juz        -> boundary        (a structural grouping that fires
///                                     "end of N" triggers, R-J1/R-J2)
///
/// `CanonicalRange`/`CanonicalPosition` (Quran.swift) keep their original
/// `surah`/`ayahStart`/`ayahEnd`/`ayah` stored properties and JSON wire keys
/// unchanged (ENGINE_PARITY §3 byte-freeze) and gain `work`/`unitStart`/
/// `unitEnd`/`unit` as additive aliases + constructors for this protocol's
/// generic callers.
public protocol ContentIndex: Sendable {
    /// Total atomic content units in the corpus (Qur'an: ayahs; poem: bayts).
    var totalUnits: Int { get }

    /// Global 0-based unit id for a canonical (work, unit) position, or nil
    /// when out of range.
    func globalIndex(of position: CanonicalPosition) -> Int?
    /// Canonical (work, unit) position for a global 0-based unit id.
    func position(ofGlobal g: Int) -> CanonicalPosition
    /// Half-open global-id range covered by a canonical range, or nil when
    /// either endpoint is out of bounds.
    func globalRange(of range: CanonicalRange) -> Range<Int>?

    /// The work (surah-equivalent) containing global position `g`.
    func workOfGlobal(_ g: Int) -> Int
    /// The 1-based unit-within-work number (ayah-equivalent) at `g`.
    func unitOfGlobal(_ g: Int) -> Int
    /// µp weight of the atomic unit at global position `g` (ENGINE_SEMANTICS §1).
    func weight(ofGlobal g: Int) -> Int64

    /// Name of this corpus's structural boundary unit ("juz" for the Qur'an;
    /// "corpus_block"/"work_boundary" for a poem collection, mirroring
    /// corpus-ref-v1's declared `boundary_kind`). Descriptive only — the
    /// engine does not branch on this string; it is surfaced for
    /// diagnostics/reporting.
    var boundaryKind: String { get }
    /// Count of structural boundaries (Qur'an: 30 juz).
    var boundaryCount: Int { get }
    /// Global-id half-open range covering boundary `n` (1-based), or nil
    /// when `n` is out of range.
    func boundaryGlobalRange(_ n: Int) -> Range<Int>?
    /// The boundary number (1-based) containing global position `g`.
    func boundaryOfGlobal(_ g: Int) -> Int
    /// Nominal µp size of exactly one boundary unit, used only for "recent N
    /// boundaries" murājaʿah pool windows (ENGINE_SEMANTICS §4 E-1b, D-043).
    /// nil when this corpus has no fixed per-boundary µp constant (e.g. a
    /// poem corpus whose works vary widely in length) — callers must treat
    /// nil as "this pool-window kind is undefined for this corpus", never
    /// substitute a guessed value.
    var boundaryUnitMicropages: Int64? { get }

    /// Resolves a DSL amount to this corpus's selection unit (PCC-3).
    /// `.unsupported` is the only case `selectNextNew` treats as a thrown,
    /// distinguishable error (the unit genuinely does not apply to this
    /// corpus); a resolvable-but-empty amount stays a legitimate nil return
    /// from the caller, not `.unsupported`.
    func amountMicropages(_ amount: QuranAmount) -> AmountResolution

    /// Checksum identifying the concrete corpus-ref document backing this
    /// index instance (cross-device consistency checks, future work).
    var refChecksum: String { get }
}

/// Corpus-aware resolution of a `QuranAmount` to its engine-selection unit.
/// See `ContentIndex.amountMicropages(_:)`.
public enum AmountResolution: Hashable, Sendable {
    /// Resolved to an exact micropage size (page/juz/hizb/rub/line-style units).
    case micropages(Int64)
    /// Resolved to a plain atomic-unit count (ayah/custom-range-style units;
    /// selection walks by count, not µp — ENGINE_SEMANTICS §1).
    case countUnit(Int)
    /// The unit does not apply to this corpus at all (PCC-3) — the caller
    /// throws rather than silently treating it as "nothing to select".
    case unsupported
}

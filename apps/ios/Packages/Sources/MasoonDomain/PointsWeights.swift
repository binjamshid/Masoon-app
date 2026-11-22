/// Points scoring basis for Track J (D-178: opt-in, off-by-default, derived-only points).
///
/// D-178 fixes the shape of the score — "a pure deterministic function of the folded event
/// log" — but not a points formula. This file supplies the formula this stage was asked to add:
///
///     points = estimatedMinutes × typeWeightPerMille × qualityMultPerMille
///
/// computed as `Int64` arithmetic, round-half-up, via `Micropage.roundHalfUp` (reused, not
/// reimplemented). This is deliberately **not** expressed in micropages (µp): µp weighs by
/// Qur'an-range size, which would let a 2-juz murājaʿah task dwarf a page of new ḥifẓ in points
/// terms — not the intent of a points system meant to reward consistent effort. `estimatedMinutes`
/// (already computed per `TaskInstance.estimatedMinutes` in the engine) is the size input instead.
///
/// `typeWeightPerMille` and `qualityMultPerMille` are both expressed "per mille" (× 1/1000, so
/// 1000 == 1.0×) to keep the whole computation in `Int64` — no floating point anywhere in this
/// engine family (ENGINE_SEMANTICS §1 precedent, `Micropage.swift`). Multiplying two per-mille
/// factors scales the result by 1000 × 1000 = 1_000_000, so the formula divides by
/// `permilleSquared` (1_000_000) with round-half-up at the end, exactly once.
///
/// `quality` reuses the existing `Strength` vocabulary (`Quran.swift`: `.weak` / `.moderate` /
/// `.strong`) rather than inventing a second three-way axis, per this stage's instructions.
/// Note `Strength.scaledFactor` (used for *workload* sizing — weak hifz needs more review volume,
/// so `.weak` scales *up*) points the opposite direction from `qualityMultPerMille` here (weak
/// *evidence quality* should earn *fewer* points, not more) — same enum, deliberately different,
/// independent numeric axis for a different purpose. Do not conflate the two.
///
/// ## Default weights
///
/// `PointsWeights.v1`'s actual numbers below are **initial placeholders**, not a tuned product
/// decision. D-178 authorizes the points *mechanism*; it does not specify per-type or
/// per-quality weights. Every task type is weighted flat at 1000‰ (1.0×) — deliberately *not*
/// differentiated per type, since inventing which task types "deserve" more points than others
/// would itself be an untuned product/pedagogy judgment call this stage has no basis for. The
/// quality multiplier (weak 800‰ / moderate 1000‰ / strong 1200‰) is a mild, directionally
/// sensible ±20% spread — enough to make quality visibly matter without being punitive (D-178's
/// "no shaming" guardrail). **Revisit both before the points UI ships (Stage 6+).**
///
/// ## Override seam
///
/// `PointsWeights` is an ordinary, constructible value — not a compile-time-only constant — so a
/// future (not-this-stage) QA/debug surface can build an alternate table (e.g. read from the
/// per-plan `plan_meta` key/value store, see `MasoonData/Rows.swift`'s `PlanMetaRow` /
/// `MasoonDB.swift`'s `plan_meta` table) and pass it into `points(...)` instead of `.v1`. This
/// file only defines the seam; it never itself reads or writes `plan_meta`.
public struct PointsWeights: Hashable, Sendable {
    /// Identifies which weights table produced a score, so a UI or debug surface can show it
    /// (D-178: "the formula is shown to the user").
    public let version: String
    public let typeWeightPerMille: [TaskType: Int64]
    public let qualityMultPerMille: [Strength: Int64]

    public init(version: String, typeWeightPerMille: [TaskType: Int64], qualityMultPerMille: [Strength: Int64]) {
        self.version = version
        self.typeWeightPerMille = typeWeightPerMille
        self.qualityMultPerMille = qualityMultPerMille
    }

    /// Both per-mille factors are scaled by 1000; their product is scaled by 1000 × 1000.
    static let permilleSquared: Int64 = 1_000_000

    /// Neutral (1.0×) fallback for a `TaskType`/`Strength` missing from a (possibly sparse,
    /// override-supplied) weights table, so an incomplete table degrades to "no adjustment"
    /// rather than a crash or a silent zero.
    static let neutralPerMille: Int64 = 1_000

    /// `points = round_half_up(estimatedMinutes × typeWeight‰ × qualityMult‰ / 1_000_000)`.
    /// Pure function of its inputs — no I/O, no stored/mutable state (D-178: replay-safe).
    public func points(estimatedMinutes: Int, taskType: TaskType, quality: Strength) -> Int64 {
        precondition(estimatedMinutes >= 0, "estimatedMinutes must be non-negative")
        let typeWeight = typeWeightPerMille[taskType] ?? PointsWeights.neutralPerMille
        let qualityMult = qualityMultPerMille[quality] ?? PointsWeights.neutralPerMille
        let numerator = Int64(estimatedMinutes) * typeWeight * qualityMult
        return Micropage.roundHalfUp(numerator, PointsWeights.permilleSquared)
    }

    /// Initial placeholder weights — see file doc comment. Not final.
    public static let v1 = PointsWeights(
        version: "points_weights_v1",
        typeWeightPerMille: Dictionary(uniqueKeysWithValues: TaskType.allCases.map { ($0, neutralPerMille) }),
        qualityMultPerMille: [.weak: 800, .moderate: 1_000, .strong: 1_200]
    )
}

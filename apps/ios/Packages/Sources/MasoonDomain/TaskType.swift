/// The closed task type vocabulary used by the curriculum schema.
public enum TaskType: String, CaseIterable, Hashable, Sendable, Codable {
    case prepDhikr = "prep_dhikr"
    case warmup = "warmup"
    case tilawah = "tilawah"
    case newHifz = "new_hifz"
    case takrar = "takrar"
    case murajaah = "murajaah"
    case listening = "listening"
    case weekendConsolidation = "weekend_consolidation"
    case tasmee = "tasmee"
    case juzReview = "juz_review"
    case juzReviewDistributed = "juz_review_distributed"
    case cycleConsolidation = "cycle_consolidation"
}

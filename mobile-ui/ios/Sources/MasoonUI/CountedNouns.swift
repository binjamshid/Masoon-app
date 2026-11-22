// Arabic numeral-noun agreement (تمييز العدد).
//
// Classical MSA numeral-noun agreement:
//   1        → the noun's own gendered "one" form (not a bare count — a full
//              word, e.g. "يوم واحد" / "دقيقة واحدة").
//   2        → the noun's dual form alone, no digit (e.g. "يومين").
//   3–10     → digit + the noun's plural, genitive (e.g. "٣ أيام").
//   11–99    → digit + the noun's SINGULAR, accusative with tanwīn fatḥa.
//              Masculine nouns not ending in tāʾ marbūṭa spell an extra
//              orthographic alif ("١١ يوماً"); nouns ending in tāʾ marbūṭa do
//              NOT — the tanwīn is unwritten, so the word is spelled exactly
//              like the bare singular ("١١ دقيقة").
//   100+     → digit + the noun's SINGULAR, unmarked (muḍāf construction,
//              e.g. "١٠٠ يوم") — spelled the same as the singular, with no
//              tanwīn at all.
//   0        → treated as the 11–99 ("many") form — there is no dedicated
//              classical zero-count construction, and this is the
//              conventional choice in modern Arabic software localization
//              (matching the "many" category's singular-accusative form).
//
// English forms need no gender/case tracking: "one X" / "two Xs" (spelled,
// matching the existing "one day"/"two days" convention) and digit + plural
// for everything else, singular only for exactly 1.

import Foundation

public struct MasoonCountedNoun: Sendable {
    let oneArabic: String
    let twoArabic: String
    /// 3–10 plural, genitive (e.g. "أيام").
    let fewPluralArabic: String
    /// 11–99 singular, accusative tanwīn (e.g. "يوماً"; "دقيقة" if the
    /// tanwīn is orthographically unwritten).
    let manySingularArabic: String
    /// 100+ singular, unmarked/muḍāf (e.g. "يوم"; often identical to
    /// `manySingularArabic` minus its tanwīn alif, or identical to it
    /// outright for tāʾ-marbūṭa nouns).
    let hundredSingularArabic: String
    let oneEnglish: String
    let twoEnglish: String
    let pluralEnglish: String

    public init(
        oneArabic: String, twoArabic: String, fewPluralArabic: String,
        manySingularArabic: String, hundredSingularArabic: String,
        oneEnglish: String, twoEnglish: String, pluralEnglish: String
    ) {
        self.oneArabic = oneArabic
        self.twoArabic = twoArabic
        self.fewPluralArabic = fewPluralArabic
        self.manySingularArabic = manySingularArabic
        self.hundredSingularArabic = hundredSingularArabic
        self.oneEnglish = oneEnglish
        self.twoEnglish = twoEnglish
        self.pluralEnglish = pluralEnglish
    }

    /// "٣ أيام" / "3 days" — the full counted phrase (digit + noun, or the
    /// spelled word for 1/2) for `count` in the numbering system `locale`
    /// implies. `count` must be non-negative (day/minute/page
    /// counts never go negative in this app).
    public func phrase(_ count: Int, locale: Locale = .current) -> String {
        precondition(count >= 0, "counted-noun phrases are defined for non-negative counts only")
        let arabic = MasoonNumerals.isArabic(locale)
        switch count {
        case 1:
            // English spells the word ("one day"), matching the app's
            // existing convention — not the digit ("1 day").
            return arabic ? oneArabic : "one \(oneEnglish)"
        case 2:
            return arabic ? twoArabic : "two \(twoEnglish)"
        default:
            let n = MasoonNumerals.format(count, locale: locale)
            guard arabic else { return "\(n) \(pluralEnglish)" }
            let mod100 = count % 100
            let noun: String
            if count != 0, mod100 >= 3, mod100 <= 10 {
                noun = fewPluralArabic
            } else if count == 0 || mod100 >= 11 {
                noun = manySingularArabic
            } else {
                // mod100 ∈ {0, 1, 2} with count ≥ 100 (the classical "muḍāf
                // to a round hundred/thousand" shape, e.g. 100, 200, 101).
                noun = hundredSingularArabic
            }
            return "\(n) \(noun)"
        }
    }
}

extension MasoonCountedNoun {
    /// يوم — day. "٣ أيام" (few) / "١١ يوماً" (many) / "١٠٠ يوم" (hundred).
    public static let day = MasoonCountedNoun(
        oneArabic: "يوم واحد", twoArabic: "يومين",
        fewPluralArabic: "أيام", manySingularArabic: "يوماً", hundredSingularArabic: "يوم",
        oneEnglish: "day", twoEnglish: "days", pluralEnglish: "days")

    /// دقيقة — minute (fem., tāʾ marbūṭa: the 11–99 and 100+ forms are
    /// spelled identically to the bare singular).
    public static let minute = MasoonCountedNoun(
        oneArabic: "دقيقة واحدة", twoArabic: "دقيقتان",
        fewPluralArabic: "دقائق", manySingularArabic: "دقيقة", hundredSingularArabic: "دقيقة",
        oneEnglish: "minute", twoEnglish: "minutes", pluralEnglish: "minutes")

    /// صفحة — page (fem., tāʾ marbūṭa).
    public static let page = MasoonCountedNoun(
        oneArabic: "صفحة واحدة", twoArabic: "صفحتان",
        fewPluralArabic: "صفحات", manySingularArabic: "صفحة", hundredSingularArabic: "صفحة",
        oneEnglish: "page", twoEnglish: "pages", pluralEnglish: "pages")

    /// نقطة — point.
    public static let point = MasoonCountedNoun(
        oneArabic: "نقطة واحدة", twoArabic: "نقطتان",
        fewPluralArabic: "نقاط", manySingularArabic: "نقطة", hundredSingularArabic: "نقطة",
        oneEnglish: "point", twoEnglish: "points", pluralEnglish: "points")
}

import Foundation

/// Caches and locks formatters keyed by locale and format options.
private final class MasoonNumberFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: NumberFormatter] = [:]

    func string(from value: NSNumber, locale: Locale, style: NumberFormatter.Style = .none,
                fractionDigits: Int = 0) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(locale.identifier)|\(style.rawValue)|\(fractionDigits)"
        let formatter: NumberFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.numberStyle = style
            formatter.locale = locale
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = fractionDigits
            formatter.maximumFractionDigits = fractionDigits
            formatters[key] = formatter
        }
        return formatter.string(from: value)
    }
}

public enum MasoonNumerals {

    private static let formatterCache = MasoonNumberFormatterCache()
    /// One absent-storage policy, independent of the UI language.
    public static let defaultPreference = "arabic_indic"

    /// Honors the locale's explicit ICU numbering system. Arabic without a
    /// numbering keyword defaults to Eastern Arabic digits (٠١٢٣…).
    public static func format(_ value: Int, locale: Locale = .current) -> String {
        formatterCache.string(from: NSNumber(value: value), locale: normalized(locale)) ?? String(value)
    }

    /// Localizes only Latin decimal digits inside a machine-authored string
    /// such as `CFBundleShortVersionString`; punctuation and non-digits remain
    /// byte-for-byte unchanged.
    public static func localizedDigits(in value: String, locale: Locale = .current) -> String {
        value.reduce(into: "") { result, character in
            if let digit = character.wholeNumberValue, character.isASCII {
                result += format(digit, locale: locale)
            } else {
                result.append(character)
            }
        }
    }

    /// The persisted spelling `arabic-indic` predates `arabic_indic`; both mean
    /// the same ICU system. Language controls wording, never overrides digits.
    public static func preferenceLocale(language: String, numerals: String = defaultPreference) -> Locale {
        Locale(identifier: "\(language == "ar" ? "ar" : "en")@numbers=\(numerals == "latin" ? "latn" : "arab")")
    }


    public static func decimal(_ value: Double, fractionDigits: Int = 1, locale: Locale = .current) -> String {
        formatterCache.string(from: NSNumber(value: value), locale: normalized(locale), style: .decimal,
                              fractionDigits: max(0, min(fractionDigits, 12))) ?? "—"
    }

    /// A proportion (0.25 -> 25%), including locale-specific percent punctuation.
    public static func percent(_ value: Double, locale: Locale = .current) -> String {
        formatterCache.string(from: NSNumber(value: value), locale: normalized(locale), style: .percent) ?? "—"
    }

    public static func bytes(_ value: Int, locale: Locale = .current) -> String {
        let bytes = Double(max(0, value))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var unit = 0
        var amount = bytes
        while amount >= 1024, unit < units.count - 1 { amount /= 1024; unit += 1 }
        return "\(decimal(amount, fractionDigits: unit > 1 && amount < 10 ? 1 : 0, locale: locale)) \(units[unit])"
    }

    public static func date(_ value: Date, locale: Locale = .current,
                            timeZone: TimeZone = .current, calendar: Calendar = Calendar(identifier: .gregorian),
                            template: String = "yMMMd") -> String {
        let formatter = DateFormatter()
        formatter.locale = normalized(locale)
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: value)
    }

    public static func time(_ value: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date(value, locale: locale, timeZone: timeZone, template: "jm")
    }

    /// Presentation of a Gregorian local date without shifting it across zones.
    public static func calendarDate(year: Int, month: Int, day: Int, locale: Locale = .current) -> String {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let value = calendar.date(from: components),
              calendar.component(.year, from: value) == year,
              calendar.component(.month, from: value) == month,
              calendar.component(.day, from: value) == day else { return "—" }
        return date(value, locale: locale, timeZone: utc)
    }

    /// Parses one unsigned integer written entirely with Latin digits,
    /// Arabic-Indic digits (`٠...٩`), or Eastern Arabic/Persian digits
    /// (`۰...۹`). Surrounding whitespace is ignored; signs, separators,
    /// letters, mixed numeral systems, and overflow are rejected.
    public static func parseInteger(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        enum DigitSet { case latin, arabicIndic, easternArabic }
        var digitSet: DigitSet?
        var result = 0
        for scalar in trimmed.unicodeScalars {
            let decoded: (set: DigitSet, value: Int)?
            switch scalar.value {
            case 0x30...0x39:
                decoded = (.latin, Int(scalar.value - 0x30))
            case 0x0660...0x0669:
                decoded = (.arabicIndic, Int(scalar.value - 0x0660))
            case 0x06F0...0x06F9:
                decoded = (.easternArabic, Int(scalar.value - 0x06F0))
            default:
                decoded = nil
            }
            guard let decoded else { return nil }
            if let digitSet, digitSet != decoded.set { return nil }
            digitSet = decoded.set
            let (timesTen, multiplyOverflow) = result.multipliedReportingOverflow(by: 10)
            guard !multiplyOverflow else { return nil }
            let (next, addOverflow) = timesTen.addingReportingOverflow(decoded.value)
            guard !addOverflow else { return nil }
            result = next
        }
        return result
    }

    /// "٣ من ٥" / "3 of 5" — used by counters for both the visible chip and
    /// the accessibility value.
    public static func progressPhrase(count: Int, target: Int, locale: Locale = .current) -> String {
        let c = format(count, locale: locale)
        let t = format(target, locale: locale)
        return isArabic(locale) ? "\(c) من \(t)" : "\(c) of \(t)"
    }

    /// "٣ متبقٍ" / "3 remaining", for progress controls.
    public static func remainingPhrase(count: Int, locale: Locale = .current) -> String {
        let c = format(count, locale: locale)
        return isArabic(locale) ? "\(c) متبقٍ" : "\(c) remaining"
    }

    /// mm:ss elapsed-time string in locale digits (timer display).
    public static func elapsedString(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = format(total / 60, locale: locale)
        let secs = total % 60
        // Keep the leading zero for seconds in both numbering systems.
        let secsPadded: String
        if secs < 10 {
            secsPadded = format(0, locale: locale) + format(secs, locale: locale)
        } else {
            secsPadded = format(secs, locale: locale)
        }
        return "\(minutes):\(secsPadded)"
    }

    public static func isArabic(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "ar"
    }

    /// Bare "ar" already implies the Eastern Arabic ("arab") numbering system;
    /// region variants that default to Latin digits (e.g. ar_MA) are normalized
    /// so the default is consistent across Arabic locales.
    public static func normalized(_ locale: Locale) -> Locale {
        guard isArabic(locale), Locale.Components(identifier: locale.identifier).numberingSystem == nil
        else { return locale }
        // Retain region/calendar keywords, not just the language identifier.
        let separator = locale.identifier.contains("@") ? ";" : "@"
        return Locale(identifier: locale.identifier + separator + "numbers=arab")
    }
}

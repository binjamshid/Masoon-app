/// Pure Gregorian civil-date arithmetic (Howard Hinnant's algorithms).
/// No Foundation `Date`/`Calendar`/`TimeZone` anywhere in the engine (ENGINE_PARITY §1).

public enum Weekday: Int, CaseIterable, Hashable, Sendable, Comparable {
    case sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6

    public init?(code: String) {
        switch code {
        case "sun": self = .sun
        case "mon": self = .mon
        case "tue": self = .tue
        case "wed": self = .wed
        case "thu": self = .thu
        case "fri": self = .fri
        case "sat": self = .sat
        default: return nil
        }
    }

    public var code: String {
        switch self {
        case .sun: return "sun"
        case .mon: return "mon"
        case .tue: return "tue"
        case .wed: return "wed"
        case .thu: return "thu"
        case .fri: return "fri"
        case .sat: return "sat"
        }
    }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int  // 1...12
    public let day: Int    // 1...31

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= LocalDate.daysInMonth(year: year, month: month) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses strict `YYYY-MM-DD`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func isLeapYear(_ y: Int) -> Bool {
        y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    /// Days since 1970-01-01 (civil), Hinnant `days_from_civil`.
    public var dayNumber: Int {
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                    // [0, 399]
        let mp = month > 2 ? month - 3 : month + 9                 // [0, 11]
        let doy = (153 * mp + 2) / 5 + day - 1                     // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy            // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of `dayNumber`, Hinnant `civil_from_days`.
    public init(dayNumber z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                                // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365   // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)          // [0, 365]
        let mp = (5 * doy + 2) / 153                               // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                       // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9                          // [1, 12]
        self.year = m <= 2 ? y + 1 : y
        self.month = m
        self.day = d
    }

    public var weekday: Weekday {
        // 1970-01-01 (dayNumber 0) was a Thursday; Weekday.sun == 0.
        let w = (dayNumber % 7 + 7 + 4) % 7
        return Weekday(rawValue: w)!
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate(dayNumber: dayNumber + days)
    }

    public static func - (lhs: LocalDate, rhs: LocalDate) -> Int {
        lhs.dayNumber - rhs.dayNumber
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        lhs.dayNumber < rhs.dayNumber
    }

    public var isoString: String {
        func pad(_ v: Int, _ width: Int) -> String {
            var s = String(v)
            while s.count < width { s = "0" + s }
            return s
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    public var description: String { isoString }
}

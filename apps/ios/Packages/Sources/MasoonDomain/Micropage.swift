/// Micropage integer arithmetic (ENGINE_SEMANTICS §1).
/// 1 page = 1_000_000 µp; no floating point anywhere in the engine.

public enum Micropage {
    public static let perPage: Int64 = 1_000_000
    public static let perJuz: Int64 = 20_000_000
    public static let perHizb: Int64 = 10_000_000
    public static let perRub: Int64 = 2_500_000
    public static let perLine: Int64 = 66_666

    /// Round-half-up of `numerator / denominator` on non-negative integers.
    public static func roundHalfUp(_ numerator: Int64, _ denominator: Int64) -> Int64 {
        precondition(denominator > 0, "denominator must be positive")
        precondition(numerator >= 0, "round-half-up is defined for non-negative values in this engine")
        return (2 * numerator + denominator) / (2 * denominator)
    }

    public static func unitMicropages(_ unit: QuranUnit) -> Int64? {
        switch unit {
        case .page: return perPage
        case .juz: return perJuz
        case .hizb: return perHizb
        case .rub: return perRub
        case .line: return perLine
        case .ayah, .customRange: return nil // resolved by ayah count, not µp
        }
    }
}

/// Exact decimal value kept as scaled integer (`value = units / 10^scale`).
/// `QuranAmount.value` is always a decimal string in fixtures (ENGINE_PARITY §4.1).
public struct DecimalValue: Hashable, Sendable, CustomStringConvertible {
    /// value == units / denominator
    public let units: Int64
    public let denominator: Int64

    public init?(string raw: String) {
        var s = Substring(raw)
        guard !s.isEmpty, !s.hasPrefix("-") else { return nil } // amounts are strictly positive-or-zero
        var intPart = Substring("")
        var fracPart = Substring("")
        if let dot = s.firstIndex(of: ".") {
            intPart = s[s.startIndex..<dot]
            fracPart = s[s.index(after: dot)...]
        } else {
            intPart = s
        }
        s = ""
        guard !intPart.isEmpty || !fracPart.isEmpty else { return nil }
        guard intPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              fracPart.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // Reject exponents implicitly (any 'e' fails the digit check above).
        var u: Int64 = Int64(intPart) ?? 0
        var den: Int64 = 1
        for ch in fracPart {
            guard u <= (Int64.max - 9) / 10, den <= Int64.max / 10 else { return nil }
            u = u * 10 + Int64(String(ch))!
            den *= 10
        }
        self.units = u
        self.denominator = den
    }

    public init(integer: Int64) {
        self.units = integer
        self.denominator = 1
    }

    /// `roundHalfUp(self × multiplier)`
    public func scaled(by multiplier: Int64) -> Int64 {
        Micropage.roundHalfUp(units * multiplier, denominator)
    }

    /// Nearest integer (round-half-up).
    public var roundedInt: Int64 {
        Micropage.roundHalfUp(units, denominator)
    }

    public var description: String {
        if denominator == 1 { return String(units) }
        return "\(units)/\(denominator)"
    }
}

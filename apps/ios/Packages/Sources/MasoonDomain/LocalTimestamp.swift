/// Pure instant→civil-time formatting, and the RFC 9562 §5.7 UUIDv7 core.
///
/// These live in `MasoonDomain` rather than `MasoonData` because two processes
/// now mint `plan_event` envelopes: the phone (`PlanStore.appendEvent`) and the
/// watch (`MasoonWatchShared`, D-199). Ingestion re-stamps a watch event's
/// `device_id` and `client_seq`, but its `event_id` and `occurred_at_local`
/// survive verbatim — so if the two ever formatted differently, D-032 ledger
/// keying and `event_id` idempotency would diverge between surfaces. Sharing
/// the implementation is the only way to guarantee they cannot; the watch
/// cannot link `MasoonData` (GRDB, and `PlanStore.deviceId(_:)` would mint it a
/// device identity).
///
/// No Foundation `Date`/`Calendar`/`TimeZone` here (ENGINE_PARITY §1) — callers
/// supply the instant as unix millis and the zone as a UTC offset in seconds.
public enum LocalTimestamp {
    /// `ISO8601` local timestamp with offset, e.g. `2026-07-12T06:40:00+03:00`
    /// (`PlanEvent.occurred_at_local`).
    public static func iso8601(unixMillis millis: Int64, utcOffsetSeconds offset: Int) -> String {
        let localMillis = millis + Int64(offset) * 1000
        let dayNumber = Int(floorDiv(localMillis, 86_400_000))
        let date = LocalDate(dayNumber: dayNumber)
        var rem = Int(localMillis - Int64(dayNumber) * 86_400_000) / 1000
        let hour = rem / 3600; rem %= 3600
        let minute = rem / 60
        let second = rem % 60

        func pad2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let sign = offset < 0 ? "-" : "+"
        let absOffset = abs(offset)
        let offH = absOffset / 3600
        let offM = (absOffset % 3600) / 60
        return "\(date.isoString)T\(pad2(hour)):\(pad2(minute)):\(pad2(second))\(sign)\(pad2(offH)):\(pad2(offM))"
    }

    /// The civil date of an instant, viewed at `offset`.
    public static func localDate(unixMillis millis: Int64, utcOffsetSeconds offset: Int) -> LocalDate {
        let localMillis = millis + Int64(offset) * 1000
        return LocalDate(dayNumber: Int(floorDiv(localMillis, 86_400_000)))
    }

    /// The leading `YYYY-MM-DD` of an `occurred_at_local` string, if well-formed.
    /// D-032's documented fallback when a legacy event carries no `payload.date`.
    public static func datePart(ofISO8601 timestamp: String) -> LocalDate? {
        guard let tIndex = timestamp.firstIndex(of: "T") else { return LocalDate(iso: timestamp) }
        return LocalDate(iso: String(timestamp[timestamp.startIndex..<tIndex]))
    }

    /// Absolute instant of a `YYYY-MM-DDTHH:MM:SS±HH:MM` timestamp, in unix
    /// seconds; nil when malformed.
    ///
    /// Needed because two `occurred_at_local` strings are **not** safely
    /// comparable as text. They carry their own UTC offsets, so across a DST
    /// transition the later instant can sort earlier lexicographically — and the
    /// watch-ingest staleness check (D-199) decides whether to keep or drop a
    /// learner's completion on exactly that comparison. Once a year, in one
    /// hour, string comparison would silently make the wrong call.
    public static func epochSeconds(fromISO8601 timestamp: String) -> Int64? {
        let chars = Array(timestamp)
        // "2026-07-12T06:40:00" is the shortest prefix we accept.
        guard chars.count >= 19, chars[4] == "-", chars[7] == "-", chars[10] == "T",
              chars[13] == ":", chars[16] == ":" else { return nil }

        func int(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let y = int(0..<4), let mo = int(5..<7), let d = int(8..<10),
              let h = int(11..<13), let mi = int(14..<16), let s = int(17..<19),
              let date = LocalDate(year: y, month: mo, day: d),
              (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s)
        else { return nil }

        var offsetSeconds = 0
        if chars.count > 19 {
            let suffix = chars[19...]
            if suffix.first == "Z" {
                offsetSeconds = 0
            } else if let sign = suffix.first, sign == "+" || sign == "-" {
                // ±HH:MM
                guard suffix.count >= 6, chars[22] == ":",
                      let oh = int(20..<22), let om = int(23..<25) else { return nil }
                let magnitude = oh * 3600 + om * 60
                offsetSeconds = sign == "-" ? -magnitude : magnitude
            } else {
                return nil
            }
        }

        let localSeconds = Int64(date.dayNumber) * 86_400 + Int64(h * 3600 + mi * 60 + s)
        return localSeconds - Int64(offsetSeconds)
    }
}

@inline(__always)
func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

/// The stateful core of the UUIDv7 generator, minus any clock or randomness
/// source — callers inject both, so `MasoonData`'s `UUIDv7Generator` (phone) and
/// `MasoonWatchShared`'s `WatchIDGenerator` (wrist) share one implementation.
///
/// Monotonicity is RFC 9562 §6.2 Method 1 (fixed-length dedicated counter):
/// `rand_a` seeds randomly with its top bit cleared on each new millisecond and
/// increments for same-millisecond calls; counter overflow borrows the next
/// millisecond. Not thread-safe by itself — each owner serialises it (the
/// `PlanStore` actor on the phone, the `WatchQueueStore` actor on the wrist).
public struct UUIDv7Core: Sendable {
    private var lastMillis: Int64 = -1
    private var counter: UInt16 = 0  // 12-bit rand_a

    public init() {}

    /// `randomBytes` is called at most twice per id (counter reseed, then the
    /// 62-bit tail), so a seeded generator stays deterministic across platforms.
    public mutating func next(millis rawMillis: Int64, randomBytes: (Int) -> [UInt8]) -> String {
        var millis = rawMillis
        if millis < lastMillis { millis = lastMillis }  // never regress
        if millis == lastMillis {
            counter &+= 1
            if counter > 0x0FFF {  // counter rollover: borrow a millisecond
                millis += 1
                reseedCounter(randomBytes)
            }
        } else {
            reseedCounter(randomBytes)
        }
        lastMillis = millis

        var bytes = [UInt8](repeating: 0, count: 16)
        // 48-bit big-endian timestamp.
        for i in 0..<6 {
            bytes[i] = UInt8((UInt64(bitPattern: millis) >> UInt64(8 * (5 - i))) & 0xFF)
        }
        // version 7 + 12-bit counter as rand_a.
        bytes[6] = 0x70 | UInt8((counter >> 8) & 0x0F)
        bytes[7] = UInt8(counter & 0xFF)
        // variant 10 + 62 random bits.
        let tail = randomBytes(8)
        bytes[8] = 0x80 | (tail[0] & 0x3F)
        for i in 0..<7 { bytes[9 + i] = tail[1 + i] }
        return UUIDv5.format(bytes)
    }

    private mutating func reseedCounter(_ randomBytes: (Int) -> [UInt8]) {
        let seed = randomBytes(2)
        // Top bit cleared: ≥ 2048 increments guaranteed before rollover.
        counter = (UInt16(seed[0] & 0x07) << 8) | UInt16(seed[1])
    }
}

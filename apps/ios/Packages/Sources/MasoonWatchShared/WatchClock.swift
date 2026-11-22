import Foundation
import MasoonDomain

/// The wrist's clock boundary, mirroring `MasoonData.WallClock`.
///
/// It is a separate protocol only because `MasoonWatchShared` cannot link
/// `MasoonData` (GRDB, and `PlanStore.deviceId(_:)` would silently mint the
/// watch a device identity). The *formatting* is not duplicated — both sides
/// call `MasoonDomain.LocalTimestamp`, so `occurred_at_local` is byte-identical
/// whichever surface produced it.
public protocol WatchClock: Sendable {
    func nowUnixMillis() -> Int64
    /// UTC offset in seconds of the IANA timezone at the given instant.
    /// Unknown identifiers resolve to 0 (UTC) rather than failing an action —
    /// losing a learner's completion is worse than an hour of skew.
    func utcOffsetSeconds(timezone: String, atUnixMillis millis: Int64) -> Int
}

extension WatchClock {
    /// `2026-07-12T06:40:00+03:00` in the **plan's** zone, not the watch's.
    public func localTimestamp(timezone: String) -> String {
        let millis = nowUnixMillis()
        return LocalTimestamp.iso8601(
            unixMillis: millis,
            utcOffsetSeconds: utcOffsetSeconds(timezone: timezone, atUnixMillis: millis))
    }

    /// Today in the **plan's** zone. A learner who flies with the watch on their
    /// wrist must still complete against the plan's day, not the local one.
    public func localDate(timezone: String) -> LocalDate {
        let millis = nowUnixMillis()
        return LocalTimestamp.localDate(
            unixMillis: millis,
            utcOffsetSeconds: utcOffsetSeconds(timezone: timezone, atUnixMillis: millis))
    }
}

/// Production wrist clock. Foundation `Date`/`TimeZone` live only here.
public struct SystemWatchClock: WatchClock {
    public init() {}

    public func nowUnixMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    public func utcOffsetSeconds(timezone: String, atUnixMillis millis: Int64) -> Int {
        guard let tz = TimeZone(identifier: timezone) else { return 0 }
        return tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}

/// UUIDv7 `event_id`s minted on the wrist.
///
/// Shares `MasoonDomain.UUIDv7Core` with the phone's `UUIDv7Generator`, so the
/// two produce structurally identical ids — which matters because a watch
/// event's `event_id` survives ingestion verbatim and is the only thing making
/// re-delivery idempotent.
public struct WatchIDGenerator: Sendable {
    private var core = UUIDv7Core()
    private let clock: any WatchClock

    public init(clock: any WatchClock = SystemWatchClock()) {
        self.clock = clock
    }

    public mutating func next() -> String {
        core.next(millis: clock.nowUnixMillis()) { count in
            (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }
    }
}

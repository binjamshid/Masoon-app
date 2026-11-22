import Foundation

/// The payload keys the two halves of the watch link agree on (D-199, D-203).
///
/// Lives in a target both app targets link, for the same reason
/// `WatchNotificationIdentifiers` does: the mechanism is an exact string match
/// across a process boundary, and a typo on either side degrades **silently**
/// — the phone would simply ignore a request it does not recognise, and the
/// wrist would wait for a snapshot that is never rebuilt. Nothing here is
/// spelled out twice.
public enum WatchLinkMessages {

    /// Phone → watch: the encoded `WatchDaySnapshot`.
    public static let snapshotKey = "snapshot"

    /// Watch → phone: the encoded `[WatchPendingEvent]` array.
    public static let recordsKey = "records"

    /// Watch → phone: "rebuild and send me today, now."
    ///
    /// The wrist can only ever *ask*. The phone owns generation — the watch has
    /// no database, no event history and no way to run the curriculum engine
    /// (see `WatchDaySnapshot`'s own doc comment) — so a refresh is a request,
    /// never something the wrist can satisfy locally. That is exactly why the
    /// button this backs reports what it managed to do rather than claiming the
    /// data is fresh.
    public static let refreshRequestKey = "masoon.request.refresh"

    /// Phone → watch, in the reply to a refresh request: whether the phone
    /// currently has an active plan to build a snapshot from.
    ///
    /// "Your phone answered and has no active plan" (signed out, or still in
    /// onboarding) is a different situation from "your phone never answered",
    /// and the wrist must not present them with the same words — the first is
    /// resolved on the phone, the second by walking closer to it.
    public static let hasActivePlanKey = "masoon.reply.hasActivePlan"

    // MARK: - Payload construction and routing
    //
    // Both sides go through these rather than subscripting the dictionary
    // themselves. The keys are a cross-process contract matched by exact
    // string, and the failure mode is silence — so the matching lives in ONE
    // place that can be tested, instead of in two files that must agree.

    /// The wrist's refresh request, as sent over both transports.
    public static func refreshRequestPayload() -> [String: Any] {
        [refreshRequestKey: true]
    }

    /// True when this payload is asking the phone to rebuild.
    public static func isRefreshRequest(_ payload: [String: Any]) -> Bool {
        payload[refreshRequestKey] != nil
    }

    /// The encoded pending-event array, or nil when this payload carries none.
    /// A refresh request that rides along with records must not be mistaken for
    /// records, and vice versa — hence two independent accessors, never an
    /// either/or.
    public static func records(in payload: [String: Any]) -> Data? {
        payload[recordsKey] as? Data
    }

    /// The encoded snapshot, or nil.
    public static func snapshot(in payload: [String: Any]) -> Data? {
        payload[snapshotKey] as? Data
    }

    /// Reads the phone's answer to a refresh request. Defaults to `true` when
    /// the key is absent: an older phone build that predates this reply still
    /// rebuilds on request, and reporting "no active plan" for it would be a
    /// lie in the more alarming direction.
    public static func hasActivePlan(inReply reply: [String: Any]) -> Bool {
        reply[hasActivePlanKey] as? Bool ?? true
    }
}

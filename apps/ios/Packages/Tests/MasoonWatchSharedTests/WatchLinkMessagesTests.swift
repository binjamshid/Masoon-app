import XCTest
@testable import MasoonWatchShared

/// D-203 — the force-sync button's wire contract.
///
/// These keys are matched by exact string across a process boundary, and every
/// way they can be wrong fails SILENTLY: the phone ignores a request it does
/// not recognise, and the wrist waits for a snapshot that is never rebuilt.
/// That is the same failure class the watch link already had (a wrist with no
/// way to ask), so the routing is tested here rather than trusted to two files
/// agreeing.
final class WatchLinkMessagesTests: XCTestCase {

    func testTheThreePayloadKeysAreDistinct() {
        let keys = [
            WatchLinkMessages.snapshotKey,
            WatchLinkMessages.recordsKey,
            WatchLinkMessages.refreshRequestKey,
            WatchLinkMessages.hasActivePlanKey,
        ]
        XCTAssertEqual(
            Set(keys).count, keys.count,
            "two link keys collided — a refresh request would be read as a snapshot, or vice versa")
    }

    func testARefreshRequestIsRecognisedAndCarriesNoRecords() {
        let payload = WatchLinkMessages.refreshRequestPayload()
        XCTAssertTrue(WatchLinkMessages.isRefreshRequest(payload))
        XCTAssertNil(WatchLinkMessages.records(in: payload))
        XCTAssertNil(WatchLinkMessages.snapshot(in: payload))
    }

    func testARecordsTransferIsNotMistakenForARefreshRequest() {
        let payload: [String: Any] = [WatchLinkMessages.recordsKey: Data([1, 2, 3])]
        XCTAssertFalse(WatchLinkMessages.isRefreshRequest(payload))
        XCTAssertEqual(WatchLinkMessages.records(in: payload), Data([1, 2, 3]))
    }

    /// The wrist sends both in ONE transfer when its queue is non-empty, so the
    /// phone must act on both — not treat them as an either/or. Reading these
    /// as mutually exclusive would silently drop either the learner's queued
    /// completions or their refresh, depending on which branch won.
    func testACombinedTransferIsBothARefreshRequestAndRecords() {
        var payload = WatchLinkMessages.refreshRequestPayload()
        payload[WatchLinkMessages.recordsKey] = Data([9])
        XCTAssertTrue(WatchLinkMessages.isRefreshRequest(payload))
        XCTAssertEqual(WatchLinkMessages.records(in: payload), Data([9]))
    }

    func testAnEmptyPayloadIsNeither() {
        let payload: [String: Any] = [:]
        XCTAssertFalse(WatchLinkMessages.isRefreshRequest(payload))
        XCTAssertNil(WatchLinkMessages.records(in: payload))
        XCTAssertNil(WatchLinkMessages.snapshot(in: payload))
    }

    func testTheReplyReportsWhetherThePhoneHasAnActivePlan() {
        XCTAssertTrue(WatchLinkMessages.hasActivePlan(
            inReply: [WatchLinkMessages.hasActivePlanKey: true]))
        XCTAssertFalse(WatchLinkMessages.hasActivePlan(
            inReply: [WatchLinkMessages.hasActivePlanKey: false]))
    }

    /// Forward compatibility: the phone and watch update independently through
    /// the App Store, so a watch running this build will meet phone builds that
    /// predate the reply. Such a phone still rebuilds on request — reporting
    /// "no active plan" for it would send the learner to check a sign-in that
    /// is perfectly fine.
    func testAnOlderPhonesReplyWithoutTheKeyIsReadAsHavingAPlan() {
        XCTAssertTrue(WatchLinkMessages.hasActivePlan(inReply: [:]))
        XCTAssertTrue(WatchLinkMessages.hasActivePlan(inReply: ["something": "else"]))
    }

    /// A non-Bool in the slot (plist coercion, a future protocol change) must
    /// not read as `false` — same reasoning as the missing-key case.
    func testANonBooleanReplyValueDoesNotReadAsNoPlan() {
        XCTAssertTrue(WatchLinkMessages.hasActivePlan(
            inReply: [WatchLinkMessages.hasActivePlanKey: "yes"]))
    }
}

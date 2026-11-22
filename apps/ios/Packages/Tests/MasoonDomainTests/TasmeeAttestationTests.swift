import XCTest
@testable import MasoonDomain

/// Tests the named-listener evidence payload.
final class TasmeeAttestationTests: XCTestCase {

    func testEvidenceJSONShapeAndNeverClaimsTeacherVerificationKind() {
        let attestation = TasmeeAttestation(musammiName: "Example Listener", time: "20:15", score: 92, mistakeCount: 1)
        let evidence = attestation.evidenceJSON()

        XCTAssertEqual(evidence["kind"]?.stringValue, TasmeeAttestation.evidenceKind)
        XCTAssertEqual(TasmeeAttestation.evidenceKind, "named_listener_attestation")
        XCTAssertNotEqual(evidence["kind"]?.stringValue, "teacher_verification",
                           "a named-listener attestation must never be recorded as a system-verified teacher call")
        XCTAssertEqual(evidence["musammi_name"]?.stringValue, "Example Listener")
        XCTAssertEqual(evidence["time"]?.stringValue, "20:15")
        XCTAssertEqual(evidence["score"]?.intValue, 92)
        XCTAssertEqual(evidence["mistake_count"]?.intValue, 1)
        // Verification is recorded in the evidence payload.
        XCTAssertEqual(evidence["verified"]?.boolValue, true)
    }

    func testIsFilledRequiresANonBlankMusammiName() {
        XCTAssertFalse(TasmeeAttestation(musammiName: "", time: "20:15", score: 0, mistakeCount: 0).isFilled)
        XCTAssertFalse(TasmeeAttestation(musammiName: "   ", time: "20:15", score: 0, mistakeCount: 0).isFilled)
        XCTAssertFalse(TasmeeAttestation(musammiName: "\n\t", time: "20:15", score: 0, mistakeCount: 0).isFilled)
        XCTAssertTrue(TasmeeAttestation(musammiName: "Example Listener", time: "20:15", score: 0, mistakeCount: 0).isFilled)
        XCTAssertTrue(TasmeeAttestation(musammiName: "  Example Listener  ", time: "20:15", score: 0, mistakeCount: 0).isFilled)
    }

    func testParseRoundTrips() throws {
        let attestation = TasmeeAttestation(musammiName: "Ustadha Salma", time: "06:05", score: 88, mistakeCount: 3)
        let parsed = try XCTUnwrap(TasmeeAttestation.parse(attestation.evidenceJSON()))
        XCTAssertEqual(parsed, attestation)
    }

    func testParseRejectsARealTeacherVerificationEvent() throws {
        let realTeacherEvidence = try JSONParser.parse(#"{"kind":"teacher_verification"}"#)
        XCTAssertNil(TasmeeAttestation.parse(realTeacherEvidence),
                     "a real teacher_verification event must never parse as a named-listener attestation")
    }

    func testParseRejectsAPartiallyShapedPayload() throws {
        let missingScore = try JSONParser.parse(
            #"{"kind":"named_listener_attestation","musammi_name":"x","time":"06:05","mistake_count":0}"#)
        XCTAssertNil(TasmeeAttestation.parse(missingScore))
    }
}

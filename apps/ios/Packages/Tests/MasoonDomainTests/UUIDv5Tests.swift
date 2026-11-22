import XCTest
@testable import MasoonDomain

final class UUIDv5Tests: XCTestCase {
    func testSHA1Vectors() {
        XCTAssertEqual(SHA1.hexDigest(Array("abc".utf8)),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hexDigest([]),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hexDigest(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        // > 64-byte message exercises multi-chunk padding.
        XCTAssertEqual(SHA1.hexDigest(Array(String(repeating: "a", count: 1000).utf8)),
                       "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    func testUUIDv5DNSVectors() {
        // Authoritative vectors, cross-checked against Python's uuid.uuid5
        // (RFC 4122 §4.3). Note: the task brief quoted
        // "…-95e3-e989aced2777" for www.example.com; the RFC-correct value —
        // SHA1(ns‖name) = 2ed6657de927468b55e12665a8aea6a22dee3e35 — is
        // "…-95e1-2665a8aea6a2" (verified with `python3 -c
        // "import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, 'www.example.com'))"`).
        let dnsNamespace = UUIDv5.parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(UUIDv5.uuid(namespace: dnsNamespace, name: "www.example.com"),
                       "2ed6657d-e927-568b-95e1-2665a8aea6a2")
        XCTAssertEqual(UUIDv5.uuid(namespace: dnsNamespace, name: "python.org"),
                       "886313e1-3b8a-5372-9b90-0c9aee199e5d")
        let urlNamespace = UUIDv5.parse("6ba7b811-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(UUIDv5.uuid(namespace: urlNamespace, name: "https://example.com"),
                       "4fd35a71-71ef-5a55-a9d9-aa75c889a6d0")
    }

    func testUUIDParseAndFormatRoundTrip() {
        let s = "00000000-0000-0000-0000-000000000001"
        XCTAssertEqual(UUIDv5.format(UUIDv5.parse(s)!), s)
        XCTAssertNil(UUIDv5.parse("not-a-uuid"))
        XCTAssertNil(UUIDv5.parse("6ba7b8109dad11d180b400c04fd430c8"))  // must be hyphenated
    }

    func testVersionAndVariantBits() {
        let ns = UUIDv5.parse("00000000-0000-0000-0000-000000000001")!
        let uuid = UUIDv5.uuid(namespace: ns, name: "2026-07-12|morning|prep|0")
        let bytes = UUIDv5.parse(uuid)!
        XCTAssertEqual(bytes[6] >> 4, 5)            // version 5
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)       // RFC 4122 variant
        XCTAssertEqual(uuid, uuid.lowercased())     // lowercase hex
    }
}

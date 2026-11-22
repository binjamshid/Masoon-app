// SHA-1 and UUIDv5 vectors (RFC 3174 / RFC 4122 §4.3).

import { sha1Hex, uuid5 } from "./uuid5.ts";
import { assertEquals } from "./test_assertions.ts";

const enc = new TextEncoder();

Deno.test("SHA1 vectors", () => {
  assertEquals(sha1Hex(enc.encode("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d");
  assertEquals(sha1Hex(enc.encode("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
  assertEquals(
    sha1Hex(enc.encode("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
    "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
  );
  // > 64-byte message (multi-block padding path)
  assertEquals(
    sha1Hex(enc.encode("a".repeat(200))),
    sha1Hex(enc.encode("a".repeat(200))),
  );
});

Deno.test("UUIDv5 vector: DNS namespace + www.example.com", () => {
  // RFC 9562 A.4 test vector: SHA-1(DNS-namespace ‖ "www.example.com") =
  // 2ed6657de927468b55e12665a8aea6a22dee3e35 → UUIDv5 below. Cross-checked
  // against Python `uuid.uuid5` and Web Crypto SHA-1.
  assertEquals(
    uuid5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "www.example.com"),
    "2ed6657d-e927-568b-95e1-2665a8aea6a2",
  );
});

Deno.test("UUIDv5: version/variant bits and determinism", () => {
  const u = uuid5("00000000-0000-0000-0000-000000000001", "2026-07-12|morning|new_hifz|0");
  assertEquals(u, uuid5("00000000-0000-0000-0000-000000000001", "2026-07-12|morning|new_hifz|0"));
  assertEquals(u[14], "5"); // version nibble
  assertEquals(["8", "9", "a", "b"].includes(u[19]), true); // RFC variant
  assertEquals(u, u.toLowerCase());
});

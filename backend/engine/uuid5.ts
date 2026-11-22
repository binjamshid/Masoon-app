// RFC 4122 §4.3 UUIDv5 with an internal synchronous SHA-1.
// crypto.subtle is async; generate() must stay synchronous, so SHA-1 is
// implemented here (pure, deterministic, no dependencies).

import { EngineError } from "./types.ts";

/** Synchronous SHA-1 over bytes. Returns 20-byte digest. */
export function sha1(data: Uint8Array): Uint8Array {
  const ml = data.length;
  // Message padding: 0x80, zeros, 64-bit big-endian bit length.
  const withOne = ml + 1;
  const paddedLen = (withOne % 64 <= 56 ? withOne + (56 - (withOne % 64)) : withOne + (120 - (withOne % 64))) + 8;
  const msg = new Uint8Array(paddedLen);
  msg.set(data);
  msg[ml] = 0x80;
  const bitLen = ml * 8; // fine for < 2^53 bits
  const hi = Math.floor(bitLen / 0x100000000);
  const lo = bitLen >>> 0;
  const dv = new DataView(msg.buffer);
  dv.setUint32(paddedLen - 8, hi);
  dv.setUint32(paddedLen - 4, lo);

  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  const w = new Int32Array(80);

  for (let off = 0; off < paddedLen; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getInt32(off + i * 4);
    for (let i = 16; i < 80; i++) {
      const x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = (x << 1) | (x >>> 31);
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let i = 0; i < 80; i++) {
      let f: number, k: number;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[i]) | 0;
      e = d;
      d = c;
      c = (b << 30) | (b >>> 2);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) | 0;
    h1 = (h1 + b) | 0;
    h2 = (h2 + c) | 0;
    h3 = (h3 + d) | 0;
    h4 = (h4 + e) | 0;
  }

  const out = new Uint8Array(20);
  const odv = new DataView(out.buffer);
  odv.setInt32(0, h0);
  odv.setInt32(4, h1);
  odv.setInt32(8, h2);
  odv.setInt32(12, h3);
  odv.setInt32(16, h4);
  return out;
}

export function sha1Hex(data: Uint8Array): string {
  return Array.from(sha1(data), (b) => b.toString(16).padStart(2, "0")).join("");
}

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function uuidToBytes(uuid: string): Uint8Array {
  if (!UUID_RE.test(uuid)) throw new EngineError(`invalid UUID: ${JSON.stringify(uuid)}`);
  const hex = uuid.replace(/-/g, "");
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function bytesToUuid(b: Uint8Array): string {
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

/** RFC 4122 §4.3 name-based UUID (version 5, SHA-1), lowercase hyphenated. */
export function uuid5(namespace: string, name: string): string {
  const ns = uuidToBytes(namespace);
  const nameBytes = new TextEncoder().encode(name);
  const input = new Uint8Array(ns.length + nameBytes.length);
  input.set(ns);
  input.set(nameBytes, ns.length);
  const hash = sha1(input).slice(0, 16);
  hash[6] = (hash[6] & 0x0f) | 0x50; // version 5
  hash[8] = (hash[8] & 0x3f) | 0x80; // RFC 4122 variant
  return bytesToUuid(hash);
}

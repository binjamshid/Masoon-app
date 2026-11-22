/// RFC 4122 §4.3 name-based UUID (version 5, SHA-1) with an internal SHA-1.
/// No third-party dependencies; `task_uid = UUIDv5(namespace: plan_id, name:
/// "{date}|{session}|{origin_rule_id}|{occurrence}")` (ENGINE_PARITY §2).

public enum SHA1 {
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        // Pre-processing: append 0x80, pad with zeros, append 64-bit big-endian bit length.
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunkStart in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = (UInt32(data[o]) << 24) | (UInt32(data[o + 1]) << 16)
                     | (UInt32(data[o + 2]) << 8) | UInt32(data[o + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(20)
        for h in [h0, h1, h2, h3, h4] {
            digest.append(UInt8((h >> 24) & 0xFF))
            digest.append(UInt8((h >> 16) & 0xFF))
            digest.append(UInt8((h >> 8) & 0xFF))
            digest.append(UInt8(h & 0xFF))
        }
        return digest
    }

    public static func hexDigest(_ message: [UInt8]) -> String {
        hash(message).map { byteHex($0) }.joined()
    }
}

@inline(__always)
private func byteHex(_ b: UInt8) -> String {
    let digits = "0123456789abcdef"
    let hi = digits[digits.index(digits.startIndex, offsetBy: Int(b >> 4))]
    let lo = digits[digits.index(digits.startIndex, offsetBy: Int(b & 0x0F))]
    return String([hi, lo])
}

public enum UUIDv5 {
    /// Parses `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` into 16 bytes.
    public static func parse(_ uuid: String) -> [UInt8]? {
        let hex = uuid.lowercased().filter { $0 != "-" }
        guard hex.count == 32, uuid.count == 36 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var iterator = hex.makeIterator()
        while let hiChar = iterator.next(), let loChar = iterator.next() {
            guard let hi = hiChar.hexDigitValue, let lo = loChar.hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
        }
        return bytes.count == 16 ? bytes : nil
    }

    public static func format(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        let hex = bytes.map { byteHex($0) }.joined()
        let h = Array(hex)
        return String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16])
             + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
    }

    /// Lowercase hyphenated UUIDv5 of `name` (UTF-8) in `namespace`.
    public static func uuid(namespace: [UInt8], name: String) -> String {
        precondition(namespace.count == 16, "namespace must be a 16-byte UUID")
        var input = namespace
        input.append(contentsOf: Array(name.utf8))
        var bytes = Array(SHA1.hash(input)[0..<16])
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return format(bytes)
    }
}

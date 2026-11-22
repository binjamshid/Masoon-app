package masoon.domain

import java.security.MessageDigest

/**
 * RFC 4122 §4.3 name-based UUID, SHA-1 variant (version 5).
 * `task_uid = UUIDv5(namespace = plan_id, name = "{date}|{session}|{origin_rule_id}|{occurrence}")`.
 */
object Uuid5 {

    /** Parse a hyphenated UUID string into its 16 big-endian bytes. */
    fun uuidBytes(uuid: String): ByteArray {
        val hex = uuid.replace("-", "")
        require(hex.length == 32) { "invalid uuid: $uuid" }
        return ByteArray(16) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    fun sha1(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-1").digest(bytes)

    fun sha1Hex(text: String): String =
        sha1(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** Lowercase hyphenated UUIDv5. */
    fun uuid5(namespace: String, name: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        md.update(uuidBytes(namespace))
        md.update(name.toByteArray(Charsets.UTF_8))
        val h = md.digest()
        val b = h.copyOf(16)
        b[6] = ((b[6].toInt() and 0x0F) or 0x50).toByte() // version 5
        b[8] = ((b[8].toInt() and 0x3F) or 0x80).toByte() // RFC 4122 variant
        val hex = b.joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-" +
            "${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }
}

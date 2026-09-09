package com.voiid.app.net

enum class CallEncryptionStatus { PENDING, VERIFIED, UNVERIFIED, MISMATCH }

/** Wire-compatible with iOS CallKeyExchange's v1 commitment. */
object CallKeyProtocol {
    fun verificationStatus(localTag: String, remoteTag: String): CallEncryptionStatus =
        if (localTag.isNotEmpty() && localTag == remoteTag) CallEncryptionStatus.VERIFIED else CallEncryptionStatus.MISMATCH

    fun fingerprint(sdp: String?): String? = sdp?.lineSequence()?.map { it.trim() }
        ?.filter { it.startsWith("a=fingerprint:") }?.mapNotNull {
            val parts = it.removePrefix("a=fingerprint:").trim().split(Regex("\\s+"), limit = 2)
            if (parts.size != 2 || parts[1].isBlank()) null
            else parts[0].lowercase(java.util.Locale.ROOT) + " " + parts[1].trim().uppercase(java.util.Locale.ROOT)
        }?.firstOrNull()

    fun commitment(masterKey: ByteArray, masterSalt: ByteArray, a: String, b: String): ByteArray {
        val hash = java.security.MessageDigest.getInstance("SHA-256")
        hash.update(masterKey)
        hash.update(masterSalt)
        for (fingerprint in listOf(a, b).sorted()) {
            hash.update(0x1f.toByte())
            hash.update(fingerprint.toByteArray(Charsets.UTF_8))
        }
        return hash.digest()
    }
}

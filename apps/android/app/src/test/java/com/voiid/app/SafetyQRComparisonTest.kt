package com.voiid.app
import com.voiid.app.main.SafetyQRComparison
import org.junit.Assert.assertEquals
import org.junit.Test
class SafetyQRComparisonTest {
    private val code = "12345".repeat(12)
    @Test fun `compares all sixty digits`() {
        assertEquals(SafetyQRComparison.Result.MATCH, SafetyQRComparison.compare(code, code.chunked(5).joinToString(" ")))
        assertEquals(SafetyQRComparison.Result.MISMATCH, SafetyQRComparison.compare(code.dropLast(1) + "6", code))
    }
    @Test fun `rejects unrelated and malformed payloads`() {
        listOf("", "https://voiid.app/" + code, code + "0", code.dropLast(1), "١".repeat(60), code + "\n").forEach {
            assertEquals(SafetyQRComparison.Result.INVALID, SafetyQRComparison.compare(it, code))
        }
        assertEquals(SafetyQRComparison.Result.INVALID, SafetyQRComparison.compare(code, ""))
    }
}

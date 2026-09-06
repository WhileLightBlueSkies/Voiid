package com.voiid.app
import com.voiid.app.net.GameSessionGuard
import org.junit.Assert.*
import org.junit.Test
class GameSessionGuardTest {
    @Test fun reopeningSameMatchInvalidatesOldWork() {
        val guard = GameSessionGuard()
        val old = guard.begin("a", false)
        guard.begin("a", false)
        assertFalse(guard.isCurrent(old))
    }
    @Test fun leavingInvalidatesPendingSnapshot() {
        val guard = GameSessionGuard()
        val pending = guard.begin("a", true)
        guard.clear()
        assertFalse(guard.isCurrent(pending))
    }
    @Test fun genericEntryNeverRequestsLudoRecovery() {
        val guard = GameSessionGuard()
        assertFalse(guard.begin("a", false).ludo)
        assertTrue(guard.begin("b", true).ludo)
    }
}

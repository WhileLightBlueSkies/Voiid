package com.voiid.app.net

/** Identity of one visit, including a retry of the same match. */
internal class GameSessionGuard {
    data class Token(val id: String, val generation: Long, val ludo: Boolean)
    private var generation = 0L
    @Volatile var current: Token? = null
        private set
    @Synchronized fun begin(id: String, ludo: Boolean): Token =
        Token(id, ++generation, ludo).also { current = it }
    fun isCurrent(token: Token): Boolean = current == token
    @Synchronized fun clear() { generation++; current = null }
}

package com.voiid.app.net

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A ring does not replace the current screen; a notification tap explicitly opens it. */
object IncomingCallPresentation {
    const val EXTRA_OPEN_CALL_ID = "voiid.call.open_id"
    data class State(val openedCallId: String? = null, val fallbackCallId: String? = null) {
        fun showsCall(callId: String, notificationsBlocked: Boolean): Boolean =
            notificationsBlocked || openedCallId == callId || fallbackCallId == callId
    }
    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()
    @Synchronized fun open(callId: String) { mutableState.value = mutableState.value.copy(openedCallId = callId) }
    @Synchronized fun useFallback(callId: String?) { mutableState.value = mutableState.value.copy(fallbackCallId = callId) }
    @Synchronized fun clear() { mutableState.value = State() }
}

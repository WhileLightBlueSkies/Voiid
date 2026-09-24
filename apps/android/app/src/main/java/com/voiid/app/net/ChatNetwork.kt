package com.voiid.app.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the phone has a route to the internet, for chat sends. Port of iOS ChatNetwork.
 *
 * A send that cannot go yet is never shown as a failure: the bubble keeps its clock, says
 * "Waiting for network" while there is no connection, and goes the moment one returns.
 * [generation] ticks up each time the connection comes back, so anything waiting between
 * retries can stop waiting and try at once.
 */
object ChatNetwork {
    /** True until the system says otherwise, so nothing reads "offline" before the first update. */
    private val _reachable = MutableStateFlow(true)
    val isReachable: StateFlow<Boolean> = _reachable.asStateFlow()

    /** Bumped on every offline → online change. */
    private val _generation = MutableStateFlow(0)
    val generation: StateFlow<Int> = _generation.asStateFlow()

    @Volatile private var started = false
    private val online = mutableSetOf<Network>()

    fun start(context: Context) {
        if (started) return
        started = true
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching {
            cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = update { online.add(network) }
                override fun onLost(network: Network) = update { online.remove(network) }
            })
        }
        // No callback fires while offline at launch, so seed from the current state.
        val caps = runCatching { cm.getNetworkCapabilities(cm.activeNetwork) }.getOrNull()
        _reachable.value = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }

    private fun update(change: () -> Unit) {
        val now = synchronized(online) { change(); online.isNotEmpty() }
        if (now != _reachable.value) {
            _reachable.value = now
            if (now) _generation.value += 1
        }
    }

    /** Sleep up to [seconds], returning early if the connection comes back meanwhile. */
    suspend fun wait(seconds: Double) {
        val start = _generation.value
        var left = seconds
        while (left > 0 && _generation.value == start) {
            delay(500)
            left -= 0.5
        }
    }
}

/**
 * Whether a failed send is worth trying again by itself, in the background. Port of iOS
 * SendRetry.
 *
 * A slow or dropped connection, a timeout, a cancelled request and a server that is briefly
 * unwell all clear up on their own — the message should wait (the clock), not turn red. Only
 * a real refusal is a failure the person has to see.
 */
object SendRetry {
    fun isRetryable(e: Throwable): Boolean = when (e) {
        is java.io.IOException -> true
        is ApiError.Transport -> true
        // 404/409: the peer has no keys yet or a session race; 408/425/429: slow down and come
        // back; 5xx: the server's problem, not the message's.
        is ApiError.Http -> e.status == 0 || e.status == 404 || e.status == 408 || e.status == 409 ||
            e.status == 425 || e.status == 429 || e.status in 500..599
        else -> e.cause?.let { it !== e && isRetryable(it) } ?: false
    }
}

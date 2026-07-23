package com.voiid.app.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest

/**
 * Watches the device's default internet transport for the lifetime of a call.
 *
 * The failure this exists to fix: a user walks out of the house, WiFi drops, the phone
 * silently swaps to LTE, and every ICE candidate the call negotiated is now bound to a dead
 * local interface. WebRTC will eventually notice (ICE goes DISCONNECTED then FAILED) but that
 * takes seconds of dead air — and on some networks it never recovers on its own. Reacting to
 * the OS's own handover signal lets us kick an ICE restart *immediately*, usually before the
 * user has finished their sentence.
 *
 * We only report a change once we've seen a genuinely different [Network] (or a different
 * transport type on the same one). The very first `onAvailable` after registering is the
 * network we're already on, so it is recorded silently — restarting there would be pointless
 * churn at the exact moment the call is being set up.
 */
class CallNetworkMonitor(
    private val context: Context,
    /** Invoked (on a binder thread) when the default transport actually changed mid-call. */
    private val onHandover: (String) -> Unit,
) {

    private var cm: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    /** Handle of the network we currently believe media is flowing over. */
    private var currentNetwork: Network? = null
    private var currentTransport: Int = -1

    fun start() {
        if (callback != null) return
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val previous = currentNetwork
                currentNetwork = network
                if (previous != null && previous != network) {
                    onHandover("network_available")
                }
            }

            override fun onLost(network: Network) {
                // Only interesting if the link we were actually using went away. Losing some
                // other idle network (a second WiFi SSID, a VPN teardown) is noise.
                if (network == currentNetwork) {
                    currentNetwork = null
                    currentTransport = -1
                }
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val transport = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkCapabilities.TRANSPORT_WIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkCapabilities.TRANSPORT_CELLULAR
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NetworkCapabilities.TRANSPORT_ETHERNET
                    else -> -1
                }
                if (network != currentNetwork) return
                val previous = currentTransport
                currentTransport = transport
                // WiFi -> cellular (or back) on the same Network handle: a real handover.
                if (previous != -1 && transport != -1 && previous != transport) {
                    onHandover("transport_changed")
                }
            }
        }

        runCatching { manager.registerNetworkCallback(request, cb) }
            .onSuccess { cm = manager; callback = cb }
    }

    fun stop() {
        val manager = cm
        val cb = callback
        cm = null
        callback = null
        currentNetwork = null
        currentTransport = -1
        if (manager != null && cb != null) runCatching { manager.unregisterNetworkCallback(cb) }
    }
}

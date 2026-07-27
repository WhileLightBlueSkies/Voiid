package com.voiid.app.model

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.voiid.app.net.MapPresenceEngine

/**
 * Thin AndroidViewModel over [MapPresenceEngine] for Feature (B), The Map.
 *
 * The engine is a process singleton (it owns the fused provider, keys and WS wiring, which must
 * survive a screen leaving). This ViewModel exists only so the Map surface can be given a store
 * the Compose way and observe the engine's StateFlows. All logic lives in the engine; nothing is
 * duplicated here — a second source of truth for "am I visible" is exactly the class of bug that
 * makes a privacy indicator lie.
 */
class MapStore(app: Application) : AndroidViewModel(app) {

    init { MapPresenceEngine.init(app) }

    val visibility get() = MapPresenceEngine.visibility
    val ghostUntil get() = MapPresenceEngine.ghostUntil
    val audience get() = MapPresenceEngine.audience
    val subjects get() = MapPresenceEngine.subjects
    /** People sharing with us who have no fix yet — shown as "waiting for location". */
    val waitingSenders get() = MapPresenceEngine.waitingSenders
    val onboarded get() = MapPresenceEngine.onboarded
    /** Non-null when going visible failed — the Map must say so rather than imply it worked. */
    val lastError get() = MapPresenceEngine.lastError

    fun setAudience(contacts: List<MapContact>) = MapPresenceEngine.setAudience(contacts)
    fun goVisible() = MapPresenceEngine.goVisible()
    fun goGhost(until: Long = 0L) = MapPresenceEngine.goGhost(until)
    fun killSwitch() = MapPresenceEngine.killSwitch()
    fun markOnboarded() = MapPresenceEngine.markOnboarded()
    fun clearError() = MapPresenceEngine.clearError()
    fun onForeground() = MapPresenceEngine.onForeground()
    fun onBackground() = MapPresenceEngine.onBackground()
    fun recomputeSubjects() = MapPresenceEngine.recomputeSubjects()
}

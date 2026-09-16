package com.voiid.app.main.walkthrough

enum class TourDestination { CHATS, MOMENTS, COMMUNITIES, GAMES }

data class AppWalkthroughStep(
    val id: String,
    val eyebrow: String,
    val title: String,
    val message: String,
    val destination: TourDestination?,
)

object AppWalkthroughPlan {
    const val VERSION = 1

    /** AI, Map and Clips are intentionally absent until both clients ship them. */
    val steps = listOf(
        AppWalkthroughStep(
            "welcome", "WELCOME TO VOIID", "Everything starts here",
            "Private conversations, disappearing moments, communities and games — organised into four simple spaces.",
            null,
        ),
        AppWalkthroughStep(
            "chats", "CHATS", "Your people, one tap away",
            "Search, start a chat, create a group, scan a profile code or open Settings from your profile. Long-press messages for replies, reactions and more.",
            TourDestination.CHATS,
        ),
        AppWalkthroughStep(
            "moments", "MOMENTS", "Share what is happening",
            "Post a photo or video for your chosen audience. Moments disappear after 24 hours, and replies return to Chats.",
            TourDestination.MOMENTS,
        ),
        AppWalkthroughStep(
            "communities", "COMMUNITIES", "Find your space",
            "Discover or create communities, then explore posts, spaces, members, events and tournaments. Host tools appear only when you are a host.",
            TourDestination.COMMUNITIES,
        ),
        AppWalkthroughStep(
            "games", "GAMES", "Play together",
            "Browse the live catalogue, accept invites, try daily challenges and follow leaderboards. Each game teaches its own controls when you open it.",
            TourDestination.GAMES,
        ),
        AppWalkthroughStep(
            "privacy", "YOU ARE IN CONTROL", "Privacy stays within reach",
            "Your profile opens privacy, encrypted backup and recovery, linked devices, storage, notifications, legal information and Help & Support.",
            null,
        ),
        AppWalkthroughStep(
            "complete", "YOU ARE READY", "Make Voiid yours",
            "Explore at your own pace. You can replay this walkthrough anytime from Help & Support.",
            null,
        ),
    )
}

sealed interface WalkthroughAdvance {
    data class ShowStep(val index: Int) : WalkthroughAdvance
    data object Completed : WalkthroughAdvance
}

class WalkthroughProgress(stepCount: Int, currentIndex: Int = 0) {
    private val safeStepCount = stepCount.coerceAtLeast(1)
    var currentIndex: Int = currentIndex.coerceIn(0, safeStepCount - 1)
        private set
    var isComplete: Boolean = false
        private set
    var isSkipped: Boolean = false
        private set

    fun advance(): WalkthroughAdvance {
        if (currentIndex >= safeStepCount - 1) {
            isComplete = true
            return WalkthroughAdvance.Completed
        }
        currentIndex += 1
        return WalkthroughAdvance.ShowStep(currentIndex)
    }

    fun goBack(): WalkthroughAdvance.ShowStep {
        currentIndex = (currentIndex - 1).coerceAtLeast(0)
        return WalkthroughAdvance.ShowStep(currentIndex)
    }

    fun skip() {
        isSkipped = true
    }
}

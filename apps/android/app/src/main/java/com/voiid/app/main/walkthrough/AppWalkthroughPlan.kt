package com.voiid.app.main.walkthrough

enum class TourDestination { CHATS, MOMENTS, COMMUNITIES, GAMES, SETTINGS }

enum class WalkthroughPresentationMode { FIRST_INCOMPLETE_VERSION, EVERY_APP_LAUNCH }

data class AppWalkthroughStep(
    val id: String,
    val eyebrow: String,
    val title: String,
    val message: String,
    val destination: TourDestination?,
    val targetId: String? = null,
    val shape: SpotlightShapeType = SpotlightShapeType.ROUNDED_RECT,
    val targetPaddingDp: Float = 8f,
    val graphicDrawableName: String? = null,
    val interactive: Boolean = false,
)

object AppWalkthroughPlan {
    const val VERSION = 3
    /** Preview mode for 0.0.3. Change this back after the walkthrough is approved. */
    val presentationMode = WalkthroughPresentationMode.EVERY_APP_LAUNCH

    fun shouldPresent(completedVersion: Int): Boolean =
        presentationMode == WalkthroughPresentationMode.EVERY_APP_LAUNCH || completedVersion < VERSION

    val steps = listOf(
        AppWalkthroughStep(
            id = "chats",
            eyebrow = "ENCRYPTED MESSAGING",
            title = "Your people, one tap away",
            message = "Start 1-on-1 chats and group threads secured with quantum-resistant keys. Long-press messages for reactions and quick replies.",
            destination = TourDestination.CHATS,
            targetId = "nav_tab_chats",
            shape = SpotlightShapeType.CIRCLE,
            targetPaddingDp = 8f,
            graphicDrawableName = "walkthrough_chats_hub",
            interactive = true,
        ),
        AppWalkthroughStep(
            id = "moments",
            eyebrow = "EPHEMERAL STORIES",
            title = "Share what is happening",
            message = "Post photo or video stories that disappear automatically after 24 hours. Control your audience and view replies directly in your chats.",
            destination = TourDestination.MOMENTS,
            targetId = "nav_tab_moments",
            shape = SpotlightShapeType.CIRCLE,
            targetPaddingDp = 8f,
            graphicDrawableName = "walkthrough_moments_camera",
            interactive = true,
        ),
        AppWalkthroughStep(
            id = "communities",
            eyebrow = "SPACES & CLUBS",
            title = "Find your space",
            message = "Discover or create public and private communities. Dive into topic channels, voice lounges, and tournament brackets.",
            destination = TourDestination.COMMUNITIES,
            targetId = "nav_tab_communities",
            shape = SpotlightShapeType.CIRCLE,
            targetPaddingDp = 8f,
            graphicDrawableName = "walkthrough_communities_spaces",
            interactive = true,
        ),
        AppWalkthroughStep(
            id = "community_search",
            eyebrow = "COMMUNITY SEARCH",
            title = "Explore & discover",
            message = "Search for topic spaces by keyword or @handle, explore trending clubs, or start your own public hub in seconds.",
            destination = TourDestination.COMMUNITIES,
            targetId = "comm_search_bar",
            shape = SpotlightShapeType.ROUNDED_RECT,
            targetPaddingDp = 6f,
            graphicDrawableName = "walkthrough_comm_search",
            interactive = true,
        ),
        AppWalkthroughStep(
            id = "games",
            eyebrow = "INSTANT PLAY",
            title = "Play together anywhere",
            message = "Jump into lightweight multiplayer games with friends with zero downloads. Complete daily challenges and climb leaderboards.",
            destination = TourDestination.GAMES,
            targetId = "nav_tab_games",
            shape = SpotlightShapeType.CIRCLE,
            targetPaddingDp = 8f,
            graphicDrawableName = "walkthrough_games_arena",
            interactive = true,
        ),
        AppWalkthroughStep(
            id = "profile",
            eyebrow = "YOUR IDENTITY",
            title = "Profile & safety",
            message = "Tap your avatar anytime to view your Safety Number, share your QR code, or jump into settings with one touch.",
            destination = TourDestination.CHATS,
            targetId = "nav_header_profile",
            shape = SpotlightShapeType.CIRCLE,
            targetPaddingDp = 6f,
            graphicDrawableName = "walkthrough_security_shield",
            interactive = true,
        ),
        AppWalkthroughStep(
            id = "settings_page",
            eyebrow = "SETTINGS & PRIVACY",
            title = "You stay in full control",
            message = "Manage double-ratchet keys, linked desktop devices, disappearing message defaults, and export offline backup phrases.",
            destination = TourDestination.SETTINGS,
            targetId = "settings_profile_card",
            shape = SpotlightShapeType.ROUNDED_RECT,
            targetPaddingDp = 6f,
            graphicDrawableName = "walkthrough_security_shield",
            interactive = true,
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

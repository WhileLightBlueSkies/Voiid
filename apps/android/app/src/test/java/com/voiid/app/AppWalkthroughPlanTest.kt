package com.voiid.app

import com.voiid.app.main.walkthrough.AppWalkthroughPlan
import com.voiid.app.main.walkthrough.WalkthroughPresentationMode
import com.voiid.app.main.walkthrough.TourDestination
import com.voiid.app.main.walkthrough.WalkthroughAdvance
import com.voiid.app.main.walkthrough.WalkthroughProgress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppWalkthroughPlanTest {
    @Test
    fun `manifest contains only features shipped on both platforms`() {
        assertEquals(
            listOf(TourDestination.CHATS, TourDestination.MOMENTS, TourDestination.COMMUNITIES, TourDestination.GAMES),
            AppWalkthroughPlan.steps.mapNotNull { it.destination },
        )
        assertEquals("welcome", AppWalkthroughPlan.steps.first().id)
        assertEquals("complete", AppWalkthroughPlan.steps.last().id)
        assertEquals(WalkthroughPresentationMode.EVERY_APP_LAUNCH, AppWalkthroughPlan.presentationMode)
        assertTrue(AppWalkthroughPlan.shouldPresent(AppWalkthroughPlan.VERSION))
    }

    @Test
    fun `progress advances backs completes and skips safely`() {
        val progress = WalkthroughProgress(AppWalkthroughPlan.steps.size)
        assertEquals(WalkthroughAdvance.ShowStep(1), progress.advance())
        assertEquals(WalkthroughAdvance.ShowStep(0), progress.goBack())
        assertEquals(WalkthroughAdvance.ShowStep(0), progress.goBack())

        repeat(AppWalkthroughPlan.steps.size - 1) { progress.advance() }
        assertEquals(WalkthroughAdvance.Completed, progress.advance())
        assertTrue(progress.isComplete)

        val skipped = WalkthroughProgress(AppWalkthroughPlan.steps.size)
        skipped.skip()
        assertTrue(skipped.isSkipped)
    }
}

package com.voiid.app

import com.voiid.app.main.walkthrough.AppWalkthroughPlan
import com.voiid.app.main.walkthrough.WalkthroughPresentationMode
import com.voiid.app.main.walkthrough.TourDestination
import com.voiid.app.main.walkthrough.WalkthroughAdvance
import com.voiid.app.main.walkthrough.WalkthroughProgress
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class AppWalkthroughPlanTest {
    @Test
    fun `manifest contains only features shipped on both platforms`() {
        assertEquals(
            listOf(
                TourDestination.CHATS,
                TourDestination.MOMENTS,
                TourDestination.COMMUNITIES,
                TourDestination.COMMUNITIES,
                TourDestination.GAMES,
                TourDestination.CHATS,
                TourDestination.SETTINGS,
            ),
            AppWalkthroughPlan.steps.mapNotNull { it.destination },
        )
        assertEquals("chats", AppWalkthroughPlan.steps.first().id)
        assertEquals("settings_page", AppWalkthroughPlan.steps.last().id)
        // Once per install or new account: shown until this version is completed, then never
        // again on relaunch.
        assertEquals(WalkthroughPresentationMode.FIRST_INCOMPLETE_VERSION, AppWalkthroughPlan.presentationMode)
        assertTrue(AppWalkthroughPlan.shouldPresent(0))
        assertTrue(AppWalkthroughPlan.shouldPresent(AppWalkthroughPlan.VERSION - 1))
        assertFalse(AppWalkthroughPlan.shouldPresent(AppWalkthroughPlan.VERSION))
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

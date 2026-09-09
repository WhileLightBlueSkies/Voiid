package com.voiid.app

import com.voiid.app.model.StoryViewReceipt
import com.voiid.app.model.isBoundTo
import org.junit.Assert.*
import org.junit.Test

class StoryReceiptBindingTest {
    private val receipt = StoryViewReceipt(story_id = "story-a", viewer_id = "viewer-a", viewed_at = 1000)

    @Test fun authenticatedViewerCanOnlyClaimTheirOwnView() {
        assertTrue(receipt.isBoundTo("STORY-A", "VIEWER-A"))
        assertFalse(receipt.copy(viewer_id = "someone-else").isBoundTo("story-a", "viewer-a"))
        assertFalse(receipt.copy(story_id = "other-story").isBoundTo("story-a", "viewer-a"))
    }

    @Test fun unsupportedReceiptOrInvalidTimestampIsRejected() {
        assertFalse(receipt.copy(v = 2).isBoundTo("story-a", "viewer-a"))
        assertFalse(receipt.copy(t = "story").isBoundTo("story-a", "viewer-a"))
        assertFalse(receipt.copy(viewed_at = 0).isBoundTo("story-a", "viewer-a"))
    }
}

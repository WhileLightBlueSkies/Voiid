package com.voiid.app.ui.components

import org.junit.Assert.*
import org.junit.Test

class PhotoGeometryTest {
    @Test fun fittedPortraitCannotPanHorizontallyUntilItFillsViewport() {
        assertEquals(PhotoPan(0f, 300f), clampPhotoPan(900f, 900f, 2f, 400f, 600f, 100f, 300f))
    }
    @Test fun landscapeUsesFittedImageNotViewportAsPanBounds() {
        assertEquals(PhotoPan(-300f, 0f), clampPhotoPan(-999f, 999f, 2.5f, 400f, 600f, 800f, 400f))
    }
    @Test fun resetAndUnmeasuredBoundsAreSafe() {
        assertEquals(PhotoPan(0f, 0f), clampPhotoPan(90f, -90f, 1f, 400f, 600f, 800f, 400f))
        assertEquals(PhotoPan(0f, 0f), clampPhotoPan(90f, -90f, 2f, 0f, 0f, 0f, 0f))
    }
    @Test fun dismissalUsesViewportAndDensityAndNeverUpwardFling() {
        assertFalse(shouldDismissPhoto(150f, 0f, 600f, 3f))
        assertTrue(shouldDismissPhoto(151f, 0f, 600f, 3f))
        assertFalse(shouldDismissPhoto(20f, 1901f, 600f, 3f))
        assertTrue(shouldDismissPhoto(20f, 5701f, 600f, 3f))
        assertFalse(shouldDismissPhoto(-20f, -6000f, 600f, 3f))
        assertFalse(shouldDismissPhoto(0f, 6000f, 0f, 3f))
    }
}

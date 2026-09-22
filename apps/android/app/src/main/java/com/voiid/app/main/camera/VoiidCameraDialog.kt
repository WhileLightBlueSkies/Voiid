package com.voiid.app.main.camera

import androidx.compose.runtime.Composable
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.main.stories.StoryCameraView

/**
 * The Voiid camera, full screen, for a single photo — chat and the profile photo. Replaces the
 * system camera intent those screens used, which had no face filters. Port of iOS presenting
 * `StoryCameraView(mode: .chatPhoto / .profilePhoto)` in a fullScreenCover.
 */
@Composable
fun VoiidPhotoCameraDialog(
    selfie: Boolean = false,
    onPhoto: (ByteArray) -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        StoryCameraView(
            photoOnly = true,
            selfie = selfie,
            onCaptured = { photo, _ ->
                onDismiss()
                if (photo != null) onPhoto(photo)
            },
            onClose = onDismiss,
        )
    }
}

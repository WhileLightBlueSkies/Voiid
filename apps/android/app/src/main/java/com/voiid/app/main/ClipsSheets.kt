package com.voiid.app.main

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.VideoCall
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.components.VoiidTextField
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** New clip upload — native modal bottom sheet (port of iOS `NewClipView` sheet). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewClipSheet(onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf(false) }

    val pickVideo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        picked = uri != null
        if (picked) haptics.success()
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background, dragHandle = null) {
        Column(
            Modifier.fillMaxWidth().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("New Clip", style = VoiidFont.headline, color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.CenterHorizontally))

            Box(
                Modifier
                    .fillMaxWidth()
                    .height(280.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(VoiidColor.fieldFill)
                    .clickable { pickVideo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(
                        if (picked) Icons.Default.CheckCircle else Icons.Default.VideoCall,
                        null, tint = VoiidColor.primary, modifier = Modifier.size(54.dp),
                    )
                    Text(
                        if (picked) "Video selected" else "Tap to pick a video",
                        style = VoiidFont.body, color = VoiidColor.textSecondary,
                    )
                }
            }

            VoiidTextField(placeholder = "Title", value = title, onValueChange = { title = it })
            VoiidTextField(placeholder = "Description", value = description, onValueChange = { description = it })

            VoiidPrimaryButton(title = "Share", enabled = picked && title.isNotEmpty()) {
                haptics.success(); onDismiss()
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

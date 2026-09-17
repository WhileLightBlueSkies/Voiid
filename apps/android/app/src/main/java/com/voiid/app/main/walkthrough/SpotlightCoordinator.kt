package com.voiid.app.main.walkthrough

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

enum class SpotlightShapeType {
    CIRCLE,
    ROUNDED_RECT,
    CAPSULE,
}

data class SpotlightTargetInfo(
    val id: String,
    val bounds: Rect,
    val shape: SpotlightShapeType,
    val cornerRadius: Dp = 12.dp,
    val padding: Dp = 8.dp,
    val interactive: Boolean = false,
)

class SpotlightRegistry {
    private val _targets = mutableStateMapOf<String, SpotlightTargetInfo>()
    val targets: Map<String, SpotlightTargetInfo> get() = _targets

    fun updateTarget(info: SpotlightTargetInfo) {
        _targets[info.id] = info
    }

    fun removeTarget(id: String) {
        _targets.remove(id)
    }
}

object WalkthroughNavigationBus {
    val openSettingsEvents = kotlinx.coroutines.flow.MutableSharedFlow<Boolean>(extraBufferCapacity = 1)
    fun setSettingsOpen(open: Boolean) {
        openSettingsEvents.tryEmit(open)
    }
}

val LocalSpotlightRegistry = compositionLocalOf { SpotlightRegistry() }

@Composable
fun Modifier.spotlightTarget(
    id: String,
    shape: SpotlightShapeType = SpotlightShapeType.ROUNDED_RECT,
    cornerRadius: Dp = 12.dp,
    padding: Dp = 8.dp,
    interactive: Boolean = false,
): Modifier {
    val registry = LocalSpotlightRegistry.current
    DisposableEffect(id, registry) {
        onDispose {
            registry.removeTarget(id)
        }
    }
    return this.then(
        Modifier.onGloballyPositioned { coordinates ->
            if (coordinates.isAttached) {
                val bounds = coordinates.boundsInRoot()
                if (bounds.width > 0 && bounds.height > 0) {
                    registry.updateTarget(
                        SpotlightTargetInfo(
                            id = id,
                            bounds = bounds,
                            shape = shape,
                            cornerRadius = cornerRadius,
                            padding = padding,
                            interactive = interactive,
                        )
                    )
                }
            }
        }
    )
}

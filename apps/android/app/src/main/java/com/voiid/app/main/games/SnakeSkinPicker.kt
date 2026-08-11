package com.voiid.app.main.games

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Choose a snake before a match — a catalogue skin, or any colour you like.
 *
 * UNLOCKS ARE ON CUMULATIVE LENGTH, NOT WINS. Gating cosmetics on winning punishes exactly
 * the players most likely to quit: someone losing every match would never unlock anything,
 * which is the opposite of what progression is for. Length accrues whether you win or lose,
 * so every match moves you forward and a bad run still pays.
 *
 * Thresholds are deliberately shallow at the start (the first unlock lands inside a couple of
 * matches) and widen after. The point is to teach that playing unlocks things, which a player
 * only learns by having it happen to them early.
 *
 * Mirrors iOS `SnakeSkinPicker.swift` — the thresholds MUST match or the same account would
 * own different skins on different devices.
 */
object SnakeSkinCatalogue {
    /** Skin id, display name, and the cumulative length needed. 0 means free from the start. */
    val unlocks = listOf(
        Triple("rainbow", "Rainbow", 0),
        Triple("candy", "Candy", 0),
        Triple("shadow", "Shadow", 150),
        Triple("frost", "Frost", 400),
        Triple("lava", "Lava", 800),
        Triple("bunny", "Bunny", 1500),
        Triple("corgi", "Corgi", 2500),
        Triple("lion", "Lion", 4000),
        Triple("unicorn", "Unicorn", 6000),
    )

    fun isUnlocked(id: String, totalLength: Int): Boolean {
        val entry = unlocks.firstOrNull { it.first == id } ?: return true
        return totalLength >= entry.third
    }
}

/** Persisted choice, so a player picks once rather than every match. */
class SnakeChoiceStore(context: Context) {
    private val prefs =
        context.getSharedPreferences("voiid_snake_choice", Context.MODE_PRIVATE)

    /** Chosen skin id, or null when a custom colour is in use. */
    val skinId: String? get() = prefs.getString(KEY_SKIN, "rainbow")

    /** Packed 0xRRGGBB custom colour, or 0 when a catalogue skin is in use. */
    val colour: Int get() = prefs.getInt(KEY_COLOUR, 0)

    fun saveSkin(id: String) {
        prefs.edit().putString(KEY_SKIN, id).remove(KEY_COLOUR).apply()
    }

    fun saveColour(rgb: Int) {
        prefs.edit().putInt(KEY_COLOUR, rgb).remove(KEY_SKIN).apply()
    }

    /**
     * Options for match creation. A custom colour travels as a packed int because the shared
     * options type is string->int across every game; the skin id travels separately.
     */
    fun matchOptions(): Map<String, Int> =
        if (colour > 0) mapOf("color" to colour) else emptyMap()

    /**
     * How the player steers.
     *
     * CROSS_CUTTING.md §12 lists this as a missing setting, and the competitor audit found it is
     * table stakes rather than a nicety — they ship two schemes with a settings tab and a
     * preview for each. One joystick is a bet that every thumb is the same.
     *
     * Mirrors iOS `SnakeChoiceStore.ControlScheme`.
     */
    enum class ControlScheme(val label: String, val detail: String) {
        /** A fixed ring, bottom-left. The knob follows the thumb inside it. */
        JOYSTICK("Joystick", "A fixed ring in the corner"),

        /**
         * Drag anywhere on the arena; the snake steers toward the drag direction.
         *
         * Suits one-handed play, which is how a game inside a messenger is actually held — and
         * it frees the bottom-left corner, which on a large phone is the hardest place for a
         * thumb to reach.
         */
        SWIPE("Swipe", "Drag anywhere to steer"),
    }

    var controlScheme: ControlScheme
        get() = runCatching {
            ControlScheme.valueOf(prefs.getString(KEY_CONTROL, null) ?: "")
        }.getOrDefault(ControlScheme.JOYSTICK)   // the scheme every existing player learned
        set(value) { prefs.edit().putString(KEY_CONTROL, value.name).apply() }

    private companion object {
        const val KEY_SKIN = "snake.skin"
        const val KEY_COLOUR = "snake.colour"
        const val KEY_CONTROL = "snake.control"
    }
}

/** A small preset palette. A full colour wheel is more choice than this screen needs. */
private val CUSTOM_COLOURS = listOf(
    0xFF3B47, 0xFF8A2B, 0xFFD93D, 0x5CE65C, 0x22E0F0,
    0x4DA8FF, 0x9B5CFF, 0xFF4FD8, 0xFFFFFF, 0x8A8AA0,
)

@Composable
fun SnakeSkinPicker(onDone: () -> Unit) {
    val context = LocalContext.current
    val store = remember { SnakeChoiceStore(context) }
    val records = remember { SnakeRecordStore(context) }
    val total = records.totalLength

    var selectedSkin by remember { mutableStateOf(store.skinId) }
    var selectedColour by remember { mutableStateOf(store.colour) }

    Column(Modifier.padding(20.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Your snake", fontSize = 20.sp, fontWeight = FontWeight.Black)
            // Progress is stated plainly. A locked item with no visible distance to it reads
            // as a paywall rather than as a goal.
            Text("$total total length", fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                color = Color.Gray)
        }

        LazyVerticalGrid(
            columns = GridCells.Adaptive(92.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(vertical = 16.dp),
        ) {
            items(SnakeSkinCatalogue.unlocks) { (id, name, requires) ->
                val unlocked = total >= requires
                SkinSwatch(
                    id = id,
                    name = name,
                    unlocked = unlocked,
                    remaining = (requires - total).coerceAtLeast(0),
                    selected = selectedSkin == id && selectedColour == 0,
                ) {
                    if (unlocked) {
                        selectedSkin = id
                        selectedColour = 0
                        store.saveSkin(id)
                    }
                }
            }
        }

        Text("Or a colour", fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CUSTOM_COLOURS.take(10).forEach { rgb ->
                Box(
                    Modifier
                        .size(28.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color(0xFF000000 or rgb.toLong()))
                        .clickable {
                            selectedColour = rgb
                            selectedSkin = null
                            store.saveColour(rgb)
                        }
                        .then(
                            if (selectedColour == rgb)
                                Modifier.background(Color.White.copy(alpha = 0.25f))
                            else Modifier
                        )
                )
            }
        }

        Box(
            Modifier
                .fillMaxWidth()
                .padding(top = 20.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(0xFF22E0F0))
                .clickable { onDone() }
                .padding(vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Done", fontSize = 16.sp, fontWeight = FontWeight.Black,
                color = Color(0xFF07060F))
        }
    }
}

@Composable
private fun SkinSwatch(
    id: String,
    name: String,
    unlocked: Boolean,
    remaining: Int,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // The swatch shows the ACTUAL bands, so what you pick is what you get.
        val skin = SnakeSkins.resolve(id, Color.Gray)
        Row(
            Modifier
                .fillMaxWidth()
                .height(34.dp)
                .clip(RoundedCornerShape(8.dp))
                .alpha(if (unlocked) 1f else 0.25f)
                .clickable(enabled = unlocked) { onClick() }
        ) {
            skin.bands.forEach { band ->
                Box(Modifier.weight(1f).fillMaxWidth().background(band).height(34.dp))
            }
        }
        Text(
            if (unlocked) name else "$remaining more",
            fontSize = 11.sp,
            fontWeight = if (selected) FontWeight.Black else FontWeight.SemiBold,
            color = if (unlocked) Color.Unspecified else Color.Gray,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

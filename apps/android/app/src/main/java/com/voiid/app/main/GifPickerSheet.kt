package com.voiid.app.main

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import com.voiid.app.net.GifService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * GIF search, backed by our own /gifs proxy in front of Tenor. Mirrors iOS `GifPickerSheet`.
 *
 * THE PRIVACY SHAPE, which is why this is not a two-line SDK drop-in:
 *  - Search goes through OUR backend, so the API key never ships in the APK and users'
 *    searches don't reach Google carrying their IP.
 *  - Picking a GIF DOWNLOADS it here, then hands the bytes to the normal `sendMedia` path —
 *    encrypted on-device, ciphertext to R2. The recipient never touches Tenor at all.
 *
 * That second point matters most. Every other messenger sends a provider URL and lets each
 * recipient fetch it, which tells a third party who received what and when, and breaks the GIF
 * permanently if the provider removes it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GifPickerSheet(
    onDismiss: () -> Unit,
    /** Handed the downloaded GIF bytes. The caller encrypts and sends via the media path. */
    onPick: (ByteArray) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var query by remember { mutableStateOf("") }
    var gifs by remember { mutableStateOf<List<GifService.Gif>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var configured by remember { mutableStateOf(true) }
    var downloading by remember { mutableStateOf<String?>(null) }
    var searchJob by remember { mutableStateOf<Job?>(null) }

    // Coil needs the GIF decoder registered explicitly, or every result renders as a static
    // first frame — which for a GIF picker is the whole feature missing.
    val gifLoader = remember {
        ImageLoader.Builder(context)
            .components {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) add(ImageDecoderDecoder.Factory())
                else add(GifDecoder.Factory())
            }
            .build()
    }

    suspend fun load(q: String?) {
        loading = true
        val res = GifService(context).search(q)
        gifs = res.gifs
        configured = res.configured
        loading = false
    }

    LaunchedEffect(Unit) { load(null) }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium, com.voiid.app.ui.components.VoiidDetent.Large),
    ) {
        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp).padding(bottom = 16.dp)) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.pill))
                    .background(VoiidColor.fieldFill)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Search, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        Text("Search GIFs", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                    }
                    BasicTextField(
                        value = query,
                        onValueChange = { q ->
                            query = q
                            // Debounced: a fast typist should produce one request per pause,
                            // not one per keystroke — each call costs us Tenor quota.
                            searchJob?.cancel()
                            searchJob = scope.launch {
                                delay(300)
                                load(q.ifBlank { null })
                            }
                        },
                        singleLine = true,
                        textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                        cursorBrush = SolidColor(VoiidColor.primary),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (query.isNotEmpty()) {
                    Icon(
                        Icons.Default.Close, "Clear", tint = VoiidColor.placeholder,
                        modifier = Modifier.size(16.dp).clickable {
                            query = ""
                            searchJob?.cancel()
                            scope.launch { load(null) }
                        },
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            when {
                // A build with no TENOR_API_KEY says so, rather than spinning forever.
                !configured -> Column(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(Icons.Default.WarningAmber, null, tint = VoiidColor.placeholder, modifier = Modifier.size(28.dp))
                    Spacer(Modifier.height(8.dp))
                    Text("GIFs aren't set up", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Text(
                        "This build has no GIF provider configured.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
                loading && gifs.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                }
                gifs.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("No GIFs found", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                }
                else -> LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(gifs, key = { it.id }) { gif ->
                        Box(
                            Modifier
                                .height(108.dp)
                                .clip(RoundedCornerShape(VoiidRadius.md))
                                .background(VoiidColor.fieldFill)
                                .clickable(enabled = downloading == null) {
                                    haptics.tap()
                                    downloading = gif.id
                                    scope.launch {
                                        // Downloaded HERE and handed over as BYTES, never as a
                                        // URL — the recipient's device must never contact Tenor.
                                        GifService(context).download(gif.url)?.let {
                                            onPick(it)
                                            onDismiss()
                                        }
                                        downloading = null
                                    }
                                },
                        ) {
                            // The PREVIEW (tinygif) in the grid — a wall of full-size GIFs
                            // would burn memory and the user's data for images being scanned.
                            AsyncImage(
                                model = gif.preview,
                                contentDescription = gif.description.ifBlank { "GIF" },
                                imageLoader = gifLoader,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                            if (downloading == gif.id) {
                                Box(
                                    Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)),
                                    contentAlignment = Alignment.Center,
                                ) { CircularProgressIndicator(color = Color.White, modifier = Modifier.size(24.dp)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

package com.voiid.app.onboarding

import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidMotion
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * The onboarding design system. Port of iOS `OnboardingKit.swift`.
 *
 * ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────────
 * Android had TWO unrelated onboarding component sets — `OnboardingBrandChrome` (pinned
 * dark, glowing mark) and `OnboardingComponents`' `OnbScaffold` (theme-aware, pill fields) —
 * and the eight screens picked between them inconsistently. They did not match each other,
 * let alone iOS, which builds all ten of its screens on this one kit. Every string or metric
 * fix therefore had to be applied twice, and the two halves drifted further apart each time.
 *
 * This is the single set. New onboarding UI is built from these pieces or it is not built.
 */

// ══════════════════════════════════════════════════════════════════════════════════
//  THE COMMITTED-DARK PALETTE
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * The palette for a screen that pins its own ground.
 *
 * ── WHY THESE ARE FIXED VALUES AND NOT `VoiidColor` TOKENS ───────────────────────
 * `VoiidColor.textPrimary` is theme-aware: near-BLACK (#101617) in light mode. Onboarding
 * pins a fixed near-black ground in BOTH themes. A screen that reads the theme-aware token
 * on that ground therefore renders near-black on near-black in light mode.
 *
 * iOS hit exactly this and fixed it by pinning the text tokens; the comment there notes why
 * it survived review — `textSecondary`'s light value is mid-grey, so half the text on the
 * screen looked correct and only the titles vanished.
 *
 * The same trap applies to fields: `VoiidColor.fieldFill` is #EDF1F1 in light mode, a
 * near-WHITE slab on this ground rather than a recessed input.
 *
 * A screen that pins its own ground must pin its own text, or it inherits a contrast
 * decision made for a surface it does not have.
 *
 * The names read `lime*` because they are the SLOTS — fill, lit edge, lower stop, label —
 * not the hue. The values are Tide (peacock teal); the reference calls the same slots
 * `cyan*`. Renaming them would churn 60-odd call sites for no visual change.
 */
object VoiidBrand {
    /** Voiid Black — the ground for every committed-dark screen. */
    val ground = Color(0xFF0B0B0B)
    /** A card sitting on the ground. */
    val card = Color(0xFF121212)
    /** A row inside a card, one step up so it separates from what it sits on. */
    val row = Color(0xFF181818)
    /** Hairlines. White at low alpha, so they stay correct if the surfaces are re-tuned. */
    val hairline = Color.White.copy(alpha = 0.07f)

    /** Tide — the brand teal. */
    val lime = Color(0xFF13828C)
    /** The mark's lit top edge, and a pill's upper stop. */
    val limeBright = Color(0xFF68B8BD)
    /** A pill's lower stop. */
    val limeDeep = Color(0xFF0E6E77)

    /** A text field's fill on this ground. */
    val field = Color(0xFF111719)
    /** A field's border, and any hairline that must read as a line rather than a glare. */
    val fieldEdge = Color(0xFF263236)
    /** Placeholder text inside a field on this ground. */
    val placeholder = Color(0xFF6D787B)

    /** Primary text on the committed-dark ground. */
    val text = Color(0xFFF6F8F8)
    /** Secondary text on the same ground. */
    val textDim = Color(0xFFA6B0B2)

    /**
     * Text on a Tide fill. WHITE — and this INVERTS what lime required: lime was a light fill
     * needing a near-black label; Tide is a mid-tone where white wins.
     */
    val onLime = Color(0xFFFFFFFF)
}

// ══════════════════════════════════════════════════════════════════════════════════
//  HEADER
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * A title, either on one line or stacked over two.
 *
 * The accent half is always the brand colour. `Stacked` puts the accent on its own line and
 * is used where the lead is long enough that one line would wrap unpredictably.
 */
sealed interface OnboardingTitleSpec {
    val lead: String
    val accent: String

    data class Inline(override val lead: String, override val accent: String) : OnboardingTitleSpec
    data class Stacked(override val lead: String, override val accent: String) : OnboardingTitleSpec
}

/** The wordmark's cap height in the header. */
val OnboardingWordmarkSize = 34

/**
 * Wordmark + title + blurb — the top of every screen in this composition.
 *
 * NOT interchangeable with `OnboardingBrandHeader` (the glowing-mark composition in
 * `OnboardingBrandChrome`). iOS documents that a screen must not mix the two; they are two
 * different designs, and a flow that alternates between them reads as two apps.
 */
@Composable
fun OnboardingHeader(
    title: OnboardingTitleSpec,
    blurb: String,
    modifier: Modifier = Modifier,
    showsWordmark: Boolean = true,
) {
    Column(
        modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
    ) {
        if (showsWordmark) {
            BrandWordmark(size = OnboardingWordmarkSize, color = Color.White,
                dotColor = VoiidBrand.lime)
        }

        when (title) {
            is OnboardingTitleSpec.Inline -> Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = VoiidBrand.text)) { append(title.lead) }
                    withStyle(SpanStyle(color = VoiidBrand.lime)) { append(title.accent) }
                },
                style = VoiidFont.rounded(26, FontWeight.Bold),
                textAlign = TextAlign.Center,
            )
            is OnboardingTitleSpec.Stacked -> Column(
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(title.lead, style = VoiidFont.rounded(26, FontWeight.Bold),
                    color = VoiidBrand.text, textAlign = TextAlign.Center)
                Text(title.accent, style = VoiidFont.rounded(26, FontWeight.Bold),
                    color = VoiidBrand.lime, textAlign = TextAlign.Center)
            }
        }

        Text(
            blurb,
            // lineSpacing(3) on iOS. 15sp copy at ~1.3 line height lands in the same place.
            style = VoiidFont.rounded(15).copy(lineHeight = 21.sp),
            color = VoiidBrand.textDim,
            textAlign = TextAlign.Center,
        )
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  CARD, ROW, DIVIDER
// ══════════════════════════════════════════════════════════════════════════════════

/** A card on the ground: radius 20, hairline stroke. */
@Composable
fun OnboardingKitCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(VoiidBrand.card)
            .border(1.dp, VoiidBrand.hairline, RoundedCornerShape(20.dp)),
        content = content,
    )
}

/**
 * The line between two rows in a card.
 *
 * Inset 68dp so it starts where the row's TEXT starts, not where its icon does — a
 * full-bleed line under a row with a leading tile cuts the tile off from its own label.
 */
@Composable
fun OnboardingRowDivider(inset: Dp = 68.dp) {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = inset)
            .height(1.dp)
            .background(VoiidBrand.hairline)
    )
}

/**
 * A row in a card: tinted tile, title, subtitle, optional chevron.
 *
 * [onClick] null makes it INFORMATIONAL — no press highlight, and [showsChevron] should be
 * false. A chevron on a row that does nothing lies about what a tap does.
 */
@Composable
fun OnboardingRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    modifier: Modifier = Modifier,
    subtitleWraps: Boolean = false,
    showsChevron: Boolean = true,
    trailingIcon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    // A row HIGHLIGHTS rather than scales. Scaling a full-width row inside a card lifts its
    // corners off the card's own edge, which reads as the row detaching.
    val bg by animateColorAsState(
        if (pressed && onClick != null) VoiidBrand.row else Color.Transparent,
        animationSpec = tween(160, easing = VoiidMotion.easeOut), label = "rowPress",
    )

    Row(
        modifier
            .fillMaxWidth()
            .background(bg)
            .then(
                if (onClick != null) Modifier.pressableRow(interaction, onClick) else Modifier
            )
            .padding(horizontal = VoiidSpacing.md, vertical = if (subtitleWraps) 9.dp else 11.dp)
            .semantics { if (onClick != null) contentDescription = "$title. $subtitle" },
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidBrand.lime.copy(alpha = 0.10f))
                .border(1.dp, VoiidBrand.lime.copy(alpha = 0.22f),
                    RoundedCornerShape(VoiidRadius.md)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = VoiidBrand.lime, modifier = Modifier.size(17.dp))
        }

        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidBrand.text)
            if (subtitleWraps) {
                Text(subtitle, style = VoiidFont.rounded(12.5f), color = VoiidBrand.textDim)
            } else {
                OnboardingFittedText(subtitle, VoiidFont.rounded(12.5f), VoiidBrand.textDim, 0.75f)
            }
        }

        when {
            trailingIcon != null ->
                Icon(trailingIcon, null, tint = VoiidBrand.lime, modifier = Modifier.size(18.dp))
            showsChevron -> Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                null,
                tint = VoiidBrand.textDim.copy(alpha = 0.7f),
                modifier = Modifier.size(15.dp),
            )
        }
    }
}

/** Row press without a ripple, sharing the caller's interaction source. */
@Composable
private fun Modifier.pressableRow(
    interaction: MutableInteractionSource,
    onClick: () -> Unit,
): Modifier = this.clickable(
    interactionSource = interaction, indication = null, onClick = onClick,
)

// ══════════════════════════════════════════════════════════════════════════════════
//  PRIVACY NOTE
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * The reassurance panel under a card — a tinted, bordered surface, not bare text.
 *
 * Port of iOS `WelcomeTermsScreen.privacyNote`. The container is the point: on the committed
 * dark ground, two lines of unenclosed text read as a caption belonging to the card above,
 * where the tinted panel reads as its own statement. Android drew the icon and text with no
 * surface at all, which is most of why the two screens did not look alike.
 *
 * The glyph is FILLED (iOS uses `checkmark.shield.fill`). An outlined shield at this size
 * disappears into the border it sits inside.
 */
@Composable
fun OnboardingPrivacyPanel(
    icon: ImageVector,
    headline: String,
    detail: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidBrand.lime.copy(alpha = 0.07f))
            .border(1.dp, VoiidBrand.lime.copy(alpha = 0.28f),
                RoundedCornerShape(VoiidRadius.lg))
            .padding(VoiidSpacing.md)
            .semantics(mergeDescendants = true) { contentDescription = "$headline $detail" },
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, null, tint = VoiidBrand.lime, modifier = Modifier.size(20.dp))

        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            OnboardingFittedText(headline, VoiidFont.rounded(14, FontWeight.SemiBold), VoiidBrand.text, 0.8f)
            Text(detail, style = VoiidFont.subhead, color = VoiidBrand.textDim)
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  FOOTER
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * The pinned bottom of a screen.
 *
 * The 28dp fade above it is load-bearing: without it, content scrolling under the footer
 * appears to slide beneath a hard edge, and a line of text half-cut by an invisible boundary
 * reads as a rendering fault rather than as scrolling.
 */
@Composable
fun OnboardingFooter(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier.fillMaxWidth()) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(28.dp)
                .background(
                    Brush.verticalGradient(
                        listOf(VoiidBrand.ground.copy(alpha = 0f), VoiidBrand.ground)
                    )
                )
        )
        Column(
            Modifier
                .fillMaxWidth()
                .background(VoiidBrand.ground)
                .padding(horizontal = VoiidSpacing.lg)
                .padding(top = VoiidSpacing.md, bottom = VoiidSpacing.lg)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
            content = content,
        )
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  BUTTON
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * The primary call to action. 56dp, teal diagonal gradient, trailing arrow.
 *
 * DISABLED MEANS DISABLED. It looks inert AND refuses the tap — a button that dims but still
 * fires teaches the user that the interface lies about what it will do.
 */
@Composable
fun OnboardingKitButton(
    title: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    busy: Boolean = false,
    usesBrandGradient: Boolean = false,
    onClick: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val alpha by androidx.compose.animation.core.animateFloatAsState(
        if (enabled) 1f else 0.35f,
        animationSpec = tween(200, easing = VoiidMotion.easeOut), label = "buttonEnabled",
    )
    Box(
        modifier
            .fillMaxWidth()
            .height(56.dp)
            .alpha(alpha)
            .clip(CircleShape)
            .background(if (usesBrandGradient) Brush.linearGradient(listOf(VoiidBrand.limeBright, VoiidBrand.lime)) else SolidColor(VoiidBrand.lime))
            .pressableClickable(enabled = enabled && !busy) { haptics.success(); onClick() },
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            CircularProgressIndicator(color = VoiidBrand.onLime, strokeWidth = 2.dp,
                modifier = Modifier.size(22.dp))
        } else {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.lg),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    title,
                    style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidBrand.onLime,
                    modifier = Modifier.weight(1f), textAlign = TextAlign.Center,
                )
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    null, tint = VoiidBrand.onLime, modifier = Modifier.size(17.dp),
                )
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  FIELD
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * A form field: leading disc, label ABOVE the input, optional trailing slot and counter.
 *
 * The label sits above rather than acting as the placeholder, because a placeholder-as-label
 * disappears the moment you type — so a half-filled form stops saying what its fields are.
 */
@Composable
fun OnboardingField(
    icon: ImageVector,
    label: String,
    prompt: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
    capitalization: KeyboardCapitalization = KeyboardCapitalization.Sentences,
    imeAction: ImeAction = ImeAction.Next,
    characterLimit: Int? = null,
    focusRequester: FocusRequester? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    var focused by remember { mutableStateOf(false) }
    val borderColor by animateColorAsState(
        if (focused) VoiidBrand.lime.copy(alpha = 0.7f) else VoiidBrand.hairline,
        animationSpec = tween(180, easing = VoiidMotion.easeOut), label = "fieldBorder",
    )
    val borderWidth by animateDpAsState(
        if (focused) 1.5.dp else 1.dp,
        animationSpec = tween(180, easing = VoiidMotion.easeOut), label = "fieldBorderWidth",
    )

    Box(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidBrand.card)
            .border(borderWidth, borderColor, RoundedCornerShape(VoiidRadius.lg)),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md, vertical = 11.dp),
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
            verticalAlignment = if (characterLimit == null) Alignment.CenterVertically
                                else Alignment.Top,
        ) {
            Box(
                Modifier.size(38.dp).clip(CircleShape)
                    .background(VoiidBrand.lime.copy(alpha = 0.10f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = VoiidBrand.lime, modifier = Modifier.size(16.dp))
            }

            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(label, style = VoiidFont.rounded(12.5f), color = VoiidBrand.textDim)
                Box {
                    if (value.isEmpty()) {
                        Text(prompt, style = VoiidFont.rounded(16),
                            color = VoiidBrand.placeholder)
                    }
                    BasicTextField(
                        value = value,
                        onValueChange = {
                            // Truncate at the KEYSTROKE, never validate on submit — an
                            // over-limit error the user cannot reach is an error nobody sees.
                            onValueChange(
                                if (characterLimit != null) it.take(characterLimit) else it
                            )
                        },
                        textStyle = VoiidFont.rounded(16).copy(color = VoiidBrand.text),
                        cursorBrush = SolidColor(VoiidBrand.lime),
                        singleLine = characterLimit == null,
                        maxLines = if (characterLimit == null) 1 else 3,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = keyboardType,
                            capitalization = capitalization,
                            imeAction = imeAction,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .onFocusChanged { focused = it.isFocused }
                            .then(
                                focusRequester?.let { Modifier.focusRequester(it) } ?: Modifier
                            ),
                    )
                }
            }

            trailing?.invoke()
        }

        if (characterLimit != null) {
            Text(
                "${value.length}/$characterLimit",
                style = VoiidFont.rounded(12).copy(fontFeatureSettings = "tnum"),
                color = VoiidBrand.textDim,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = VoiidSpacing.md, bottom = 10.dp),
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  STEP DOTS
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * Progress across a multi-page step. The current dot is a 20dp capsule; the rest are 6dp
 * circles, so position reads without counting.
 */
@Composable
fun StepDots(current: Int, total: Int, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .clearAndSetSemantics { contentDescription = "Step ${current + 1} of $total" },
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(total) { index ->
            val selected = index == current
            val width by animateDpAsState(
                if (selected) 20.dp else 6.dp,
                animationSpec = tween(250, easing = VoiidMotion.easeOut), label = "stepDotWidth",
            )
            val color by animateColorAsState(
                if (selected) VoiidBrand.lime else VoiidBrand.fieldEdge,
                animationSpec = tween(250, easing = VoiidMotion.easeOut), label = "stepDotColor",
            )
            Box(
                Modifier
                    .size(width = width, height = 6.dp)
                    .clip(CircleShape)
                    .background(color)
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  SCAFFOLD
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * The page every onboarding screen sits in: the pinned ground, a scrolling body, and a
 * footer that never scrolls.
 *
 * The ground is [VoiidBrand.ground] and NOT `VoiidColor.background`. Onboarding is a
 * committed-dark surface on both platforms; five Android screens previously used the
 * theme-aware token, so a user in light mode walked dark → light → dark through signup.
 */
@Composable
fun OnboardingScaffold(
    modifier: Modifier = Modifier,
    scrollState: ScrollState = rememberScrollState(),
    dismissKeyboardOnTap: Boolean = true,
    /** Non-null draws iOS's round glass back chip top-left. Null on a stack root. */
    onBack: (() -> Unit)? = null,
    footer: @Composable (ColumnScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val focus = LocalFocusManager.current
    Column(
        modifier
            .fillMaxSize()
            .background(VoiidBrand.ground)
            .then(
                if (dismissKeyboardOnTap) {
                    Modifier.pointerInput(Unit) {
                        detectTapGestures(onTap = { focus.clearFocus() })
                    }
                } else Modifier
            ),
    ) {
        if (onBack != null) Box(Modifier.statusBarsPadding()) { OnboardingBackChip(onBack) }
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(scrollState)
                .then(if (onBack == null) Modifier.statusBarsPadding() else Modifier)
                .padding(horizontal = VoiidSpacing.lg),
            content = content,
        )
        footer?.let { OnboardingFooter(content = it) }
    }
}

/**
 * iOS's navigation back button on the committed-dark ground: a 44dp glass circle with a
 * chevron, top-left. Twin of the NavigationStack back chip on Permissions / Phone / OTP.
 */
@Composable
fun OnboardingBackChip(onBack: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Box(
        Modifier
            .padding(start = VoiidSpacing.md, top = VoiidSpacing.sm)
            .size(44.dp)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.10f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), CircleShape)
            .clickable { haptics.tap(); onBack() }
            .semantics { contentDescription = "Back" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null, tint = VoiidBrand.text, modifier = Modifier.size(26.dp))
    }
}

/** Mirrors iOS minimumScaleFactor; wrap instead of clipping at large accessibility sizes. */
@Composable
private fun OnboardingFittedText(text: String, style: TextStyle, color: Color, minimumScale: Float) {
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val density = androidx.compose.ui.platform.LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val width = with(density) { maxWidth.roundToPx() }
        val fitted = remember(text, style, width, density.fontScale) {
            var candidate = style
            for (step in 0..10) {
                candidate = style.copy(fontSize = style.fontSize * (1f - (1f - minimumScale) * step / 10f))
                val layout = measurer.measure(text, candidate, softWrap = false)
                if (layout.size.width <= width) break
            }
            candidate
        }
        Text(text, style = if (density.fontScale > 1.3f) style else fitted, color = color)
    }
}

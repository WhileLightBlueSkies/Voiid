package com.voiid.app.main.clips

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChildCare
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidSpacing

/** Port of iOS `ClipsGuidelinesSheet`: the full Community Guidelines, with an agree button. */
@Composable
fun ClipsGuidelinesSheet(accepted: Boolean, onAgree: () -> Unit, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().navigationBarsPadding()) {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = VoiidSpacing.md)) {
                    Text("Close", style = VoiidFont.rounded(17), color = VoiidColor.primary,
                        modifier = Modifier.align(Alignment.CenterStart).softClickable { onClose() })
                    Text("Community Guidelines", style = VoiidFont.rounded(17, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary, modifier = Modifier.align(Alignment.Center))
                }
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(VoiidSpacing.md).padding(bottom = 120.dp),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.lg),
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("What you can and can’t post", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
                        Text("These apply to every Clip, comment, handle, bio and profile photo on Voiid. They apply the same way to everyone.",
                            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                    }
                    Guidelines.forEach { RuleBlock(it) }
                    NoteBlock("What happens if you break them",
                        "We remove content that breaks these rules. Depending on what it is, we may also limit who can see your Clips, suspend your ability to post, or remove your account. Sexual content involving minors and credible threats of violence are removed immediately and reported to the authorities.",
                        VoiidColor.error.copy(alpha = 0.08f), VoiidColor.error.copy(alpha = 0.3f))
                    NoteBlock("If you see something",
                        "Every Clip and every profile has a Report option, and you can block anyone from your own profile at any time. Reports are reviewed, and we act on the serious ones within 24 hours.",
                        VoiidColor.primary.copy(alpha = 0.07f), VoiidColor.primary.copy(alpha = 0.25f))
                }
            }
            Box(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(VoiidColor.background.copy(alpha = 0f), VoiidColor.background.copy(alpha = 0.85f), VoiidColor.background)))
                    .padding(horizontal = VoiidSpacing.md, vertical = 12.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(VoiidColor.primary)
                        .softClickable { onAgree() }.padding(vertical = 15.dp),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(if (accepted) Icons.Filled.CheckCircle else Icons.Filled.Check, null, tint = Color.White, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (accepted) "Agreed" else "I agree to these guidelines", style = VoiidFont.rounded(16, FontWeight.Bold), color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun RuleBlock(rule: Guideline) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(14.dp)).padding(VoiidSpacing.md),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(rule.icon, null, tint = rule.tint, modifier = Modifier.width(22.dp).size(18.dp))
            Text(rule.title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        }
        rule.points.forEach { point ->
            Row(Modifier.padding(start = 32.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("•", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                Text(point, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary, textAlign = TextAlign.Start)
            }
        }
    }
}

@Composable
private fun NoteBlock(title: String, body: String, fill: Color, stroke: Color) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(fill)
            .border(1.dp, stroke, RoundedCornerShape(14.dp)).padding(VoiidSpacing.md),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text(body, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
}

private class Guideline(val title: String, val icon: ImageVector, val tint: Color, val points: List<String>)

private val Guidelines = listOf(
    Guideline("Treat people decently", Icons.Filled.People, Color(0xFF4ADE80), listOf(
        "No harassment, bullying, or pile-ons — including in comments.",
        "No hate speech or slurs targeting anyone’s race, religion, caste, gender, sexuality, disability or nationality.",
        "No posting someone’s private information: address, phone number, ID documents.",
        "No impersonating another person, creator or organisation.",
    )),
    Guideline("Keep people safe", Icons.Filled.Shield, Color(0xFFF59E0B), listOf(
        "No threats of violence, and nothing encouraging or organising it.",
        "No content promoting self-harm, suicide or eating disorders.",
        "No dangerous challenges or stunts people could copy and get hurt by.",
        "No sale of weapons, drugs or other illegal goods.",
    )),
    Guideline("Protect minors", Icons.Filled.ChildCare, Color(0xFFF87171), listOf(
        "Absolutely no sexual content involving anyone under 18. This is removed immediately and reported.",
        "No sexualising minors, in any form, including animation or AI-generated material.",
        "You must be 13 or older to have a Social Profile.",
    )),
    Guideline("Keep it appropriate", Icons.Filled.VisibilityOff, Color(0xFFA78BFA), listOf(
        "No pornography or sexually explicit content.",
        "No graphic violence or gore posted for shock value.",
        "Mark sensitive content as sensitive when you post it.",
    )),
    Guideline("Be real", Icons.Filled.Verified, Color(0xFF38BDF8), listOf(
        "No spam, engagement farming, or bulk-posting the same Clip.",
        "No scams, fake giveaways or misleading financial claims.",
        "Don’t post other people’s work as your own — credit the original creator.",
        "Label AI-generated content that could be mistaken for real footage.",
    )),
)

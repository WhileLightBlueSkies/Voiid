package com.voiid.app.main

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.VoiidDialogCustom
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * "Use your college email" — what joining an institution community asks first (088). Port of
 * iOS `CollegeEmailSheet`. The server checks everything and the join route refuses anyone who
 * hasn't done this; this dialog only walks people through it, then [onVerified] retries the join.
 */
@Composable
fun CollegeEmailDialog(card: CommunityService.CommunityCard, onDismiss: () -> Unit, onVerified: () -> Unit) {
    val ctx = LocalContext.current
    val service = remember { CommunityService(ctx) }
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var codeSent by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val domains = card.email_domains
    val domainText = domains.joinToString(" or ") { "@$it" }
    val trimmed = email.trim().lowercase()
    val host = trimmed.substringAfterLast('@', "")
    // Same rule as the server: the host is a domain or a subdomain of one.
    val matches = trimmed.indexOf('@') > 0 && domains.any { host == it || host.endsWith(".$it") }

    fun send() {
        busy = true; error = null
        scope.launch {
            try { service.startEmailVerification(card.id, trimmed); codeSent = true; code = "" }
            catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: "Couldn't send the code. Try again." }
            finally { busy = false }
        }
    }

    VoiidDialogCustom(onDismissRequest = { if (!busy) onDismiss() }) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            InstitutionMark(card.institution_name)
            Text(if (codeSent) "Check your inbox" else "Use your college email", style = MaterialTheme.typography.headlineSmall)
            Text(if (codeSent) "We sent a 6-digit code to $trimmed. It expires in 10 minutes."
                 else "${card.name} is only for people with a $domainText email. We'll send you a code to confirm it's yours.",
                color = VoiidColor.textSecondary)
            if (codeSent) {
                OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, singleLine = true, enabled = !busy,
                    label = { Text("6-digit code") }, modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
            } else {
                OutlinedTextField(email, { email = it.trim() }, singleLine = true, enabled = !busy,
                    label = { Text(domains.firstOrNull()?.let { "you@$it" } ?: "College email") }, modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    supportingText = { if (email.contains("@") && !matches) Text("Use your $domainText address.") })
            }
            error?.let { Text(it, color = VoiidColor.error) }
            Button(enabled = !busy && (if (codeSent) code.length == 6 else matches),
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp), onClick = {
                    if (!codeSent) send() else {
                        busy = true; error = null
                        scope.launch {
                            try { service.confirmEmailVerification(card.id, trimmed, code); onDismiss(); onVerified() }
                            catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: "That code didn't work. Try again." }
                            finally { busy = false }
                        }
                    }
                }) { Text(if (busy) "Please wait…" else if (codeSent) "Verify and join" else "Send code") }
            Row {
                if (codeSent) {
                    TextButton(enabled = !busy, onClick = { codeSent = false; code = ""; error = null }) { Text("Different email") }
                    Spacer(Modifier.weight(1f))
                    TextButton(enabled = !busy, onClick = { send() }) { Text("Resend code") }
                } else {
                    Spacer(Modifier.weight(1f))
                    TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") }
                }
            }
        }
    }
}

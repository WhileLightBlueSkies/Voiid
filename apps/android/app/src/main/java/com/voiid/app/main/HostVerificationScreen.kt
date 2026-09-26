package com.voiid.app.main

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ApiError
import com.voiid.app.net.KycService
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream

/**
 * "Get verified to sell tickets" — the host's side of KYC. Port of iOS `HostVerificationView`;
 * the two show the same five states (unavailable, form, rejected + form, in review, verified)
 * with the same copy.
 *
 * The PAN and account number live in this screen's state only until Submit returns, then they
 * are cleared. Voiid keeps the last four characters; Cashfree checks the rest.
 */
@Composable
fun HostVerificationScreen(onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    val service = remember { KycService(ctx) }
    val scope = rememberCoroutineScope()

    var status by remember { mutableStateOf<KycService.Verification?>(null) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var retry by remember { mutableStateOf(0) }

    var legalName by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var pan by remember { mutableStateOf("") }
    var account by remember { mutableStateOf("") }
    var accountAgain by remember { mutableStateOf("") }
    var ifsc by remember { mutableStateOf("") }
    // Paid to a bank account or to a UPI ID — Cashfree pays out to either.
    var payoutUpi by remember { mutableStateOf(false) }
    var upi by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var submitError by remember { mutableStateOf<String?>(null) }

    var docKind by remember { mutableStateOf(KycService.DocumentKind.PAN_CARD) }
    var kindMenu by remember { mutableStateOf(false) }
    var uploading by remember { mutableStateOf(false) }
    var uploadError by remember { mutableStateOf<String?>(null) }
    var aadhaarBusy by remember { mutableStateOf(false) }
    var aadhaarError by remember { mutableStateOf<String?>(null) }

    // Back from DigiLocker (or closed early): either way the server says whether it's done.
    val digilocker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        scope.launch {
            try { status = service.completeAadhaar() }
            catch (e: CancellationException) { throw e } catch (e: Exception) { aadhaarError = e.message ?: "Couldn't verify with DigiLocker. Try again." }
            finally { aadhaarBusy = false }
        }
    }

    LaunchedEffect(retry) {
        try {
            val v = service.me()
            status = v; loadError = null
            if (legalName.isEmpty()) legalName = v.legal_name ?: ""
            if (email.isEmpty()) email = v.email ?: ""
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            loadError = e.message ?: "Check your connection and try again."
        }
    }

    val formProblem: String? = when {
        legalName.trim().length < 2 -> "Enter your full name as on your PAN."
        !email.contains("@") || !email.contains(".") -> "Enter your email."
        !Regex("^[A-Z]{5}[0-9]{4}[A-Z]$").matches(pan) -> "Enter a valid PAN, e.g. ABCDE1234F."
        payoutUpi && !Regex("^[a-z0-9._-]{2,256}@[a-z][a-z0-9.-]{1,64}$").matches(upi) -> "Enter your UPI ID, e.g. name@okhdfcbank."
        payoutUpi -> null
        account.length < 6 -> "Enter your bank account number."
        account != accountAgain -> "The account numbers don't match."
        !Regex("^[A-Z]{4}0[A-Z0-9]{6}$").matches(ifsc) -> "Enter a valid IFSC, e.g. HDFC0001234."
        else -> null
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            uploading = true; uploadError = null
            try {
                // BitmapFactory, not ImageDecoder: minSdk is 24 and ImageDecoder arrived in 28.
                val bitmap = ctx.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
                    ?: error("Couldn't read that photo.")
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                service.upload(out.toByteArray(), docKind)
                status = service.me()
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                uploadError = e.message ?: "Upload failed. Try again."
            } finally { uploading = false }
        }
    }

    EventControlPage("Get verified", { if (!submitting && !uploading) onDismiss() }, closeLabel = "Close") {
        LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            val v = status
            when {
                loadError != null -> item {
                    Message("Couldn't load", loadError!!)
                    TextButton(onClick = { retry++ }) { Text("Retry") }
                }
                v == null -> item { CircularProgressIndicator() }
                !v.available && !v.isVerified -> item {
                    Message("Paid events are coming soon", "Voiid can't verify hosts yet. Free events work as usual.")
                }
                v.isVerified -> {
                    item { Message("You're verified", "You can sell tickets in communities you own. Your share of each sale is paid to ${if (v.payout_method == "upi") "your UPI ID ${v.upi_masked ?: ""}" else "the bank account ending ${v.bank_last4 ?: "••••"}"}.") }
                    item { PayoutSummary(v) }
                }
                v.isInReview -> {
                    item { Message("We're reviewing your details", "Your PAN and payout account passed the automatic checks. Voiid reviews every host before they can take payments — usually within a day. Adding a document can speed it up.") }
                    item { PayoutSummary(v) }
                    item {
                        Surface(shape = RoundedCornerShape(22.dp), color = VoiidColor.surfaceCard) {
                            Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                Text("Aadhaar", style = MaterialTheme.typography.titleMedium)
                                if (v.aadhaar_verified) {
                                    Text("Verified with DigiLocker · Aadhaar ending ${v.aadhaar_last4 ?: "••••"}")
                                } else {
                                    Text(if (v.aadhaar_required) "Needed before Voiid can approve you." else "Optional, but speeds up review.",
                                        color = VoiidColor.textSecondary)
                                    Button(enabled = !aadhaarBusy, modifier = Modifier.fillMaxWidth(), onClick = {
                                        aadhaarBusy = true; aadhaarError = null
                                        scope.launch {
                                            try {
                                                val url = service.startAadhaar()
                                                digilocker.launch(android.content.Intent(ctx, com.voiid.app.payments.DigiLockerActivity::class.java).putExtra("url", url))
                                            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                                                aadhaarError = e.message ?: "Couldn't open DigiLocker. Try again."; aadhaarBusy = false
                                            }
                                        }
                                    }) { Text(if (aadhaarBusy) "Please wait…" else "Verify Aadhaar with DigiLocker") }
                                    Text("You'll sign in to DigiLocker with your Aadhaar and an OTP. Voiid only receives the last four digits — never your full Aadhaar number.",
                                        style = MaterialTheme.typography.bodySmall, color = VoiidColor.textSecondary)
                                    aadhaarError?.let { Text(it, color = VoiidColor.error) }
                                }
                            }
                        }
                    }
                    item {
                        Surface(shape = RoundedCornerShape(22.dp), color = VoiidColor.surfaceCard) {
                            Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                Text("Documents (optional)", style = MaterialTheme.typography.titleMedium)
                                v.documents.forEach { doc ->
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(KycService.DocumentKind.entries.firstOrNull { it.wire == doc.kind }?.title ?: doc.kind, Modifier.weight(1f))
                                        TextButton(enabled = !uploading, onClick = {
                                            scope.launch {
                                                try { service.removeDocument(doc.id); status = service.me() }
                                                catch (e: CancellationException) { throw e } catch (e: Exception) { uploadError = e.message }
                                            }
                                        }) { Text("Remove") }
                                    }
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        TextButton(onClick = { kindMenu = true }) { Text(docKind.title) }
                                        DropdownMenu(expanded = kindMenu, onDismissRequest = { kindMenu = false }) {
                                            KycService.DocumentKind.entries.forEach { k ->
                                                DropdownMenuItem(text = { Text(k.title) }, onClick = { docKind = k; kindMenu = false })
                                            }
                                        }
                                    }
                                    OutlinedButton(enabled = !uploading, onClick = {
                                        picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                                    }) { Text(if (uploading) "Uploading…" else "Add photo") }
                                }
                                uploadError?.let { Text(it, color = VoiidColor.error) }
                                Text("Photos go straight to private storage. Only Voiid reviewers can open them.",
                                    style = MaterialTheme.typography.bodySmall, color = VoiidColor.textSecondary)
                            }
                        }
                    }
                }
                else -> {
                    if (v.isRejected && v.rejection_reason != null) item {
                        Message("Your last application wasn't approved", v.rejection_reason, tone = VoiidColor.error)
                    }
                    item {
                        Text("Verify to sell tickets", style = MaterialTheme.typography.headlineMedium)
                        Text("Ticket money is paid to your bank account or UPI ID, so we need to confirm who you are. It takes about two minutes. Free events never need this.",
                            color = VoiidColor.textSecondary)
                    }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            com.voiid.app.ui.components.VoiidOutlinedField(legalName, { legalName = it.take(100) }, label = { Text("Full name as on your PAN") },
                                singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
                            com.voiid.app.ui.components.VoiidOutlinedField(email, { email = it.trim().take(200) }, label = { Text("Email for payout updates") },
                                singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                            com.voiid.app.ui.components.VoiidOutlinedField(pan, { pan = it.uppercase().filter(Char::isLetterOrDigit).take(10) }, label = { Text("PAN") },
                                singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                val pick: @Composable (Boolean, String) -> Unit = { isUpi, label ->
                                    if (payoutUpi == isUpi) Button(onClick = {}, enabled = !submitting, modifier = Modifier.weight(1f)) { Text(label) }
                                    else OutlinedButton(onClick = { payoutUpi = isUpi }, enabled = !submitting, modifier = Modifier.weight(1f)) { Text(label) }
                                }
                                pick(false, "Bank account"); pick(true, "UPI ID")
                            }
                            if (payoutUpi) {
                                com.voiid.app.ui.components.VoiidOutlinedField(upi, { upi = it.lowercase().filterNot(Char::isWhitespace).take(100) }, label = { Text("UPI ID for payouts") },
                                    placeholder = { Text("name@okhdfcbank") }, singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, autoCorrectEnabled = false))
                            } else {
                            Text("Bank account for payouts", style = MaterialTheme.typography.titleMedium)
                            com.voiid.app.ui.components.VoiidOutlinedField(account, { account = it.filter(Char::isLetterOrDigit).take(40) }, label = { Text("Account number") },
                                singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
                            com.voiid.app.ui.components.VoiidOutlinedField(accountAgain, { accountAgain = it.filter(Char::isLetterOrDigit).take(40) }, label = { Text("Re-enter account number") },
                                singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                            com.voiid.app.ui.components.VoiidOutlinedField(ifsc, { ifsc = it.uppercase().filter(Char::isLetterOrDigit).take(11) }, label = { Text("IFSC") },
                                singleLine = true, enabled = !submitting, modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false))
                            }
                            Text("Cashfree deposits ₹1 to check the account. Voiid keeps only the last four digits of your PAN and account.",
                                style = MaterialTheme.typography.bodySmall, color = VoiidColor.textSecondary)
                            submitError?.let { Text(it, color = VoiidColor.error) }
                            if (formProblem != null && (legalName.isNotEmpty() || pan.isNotEmpty() || account.isNotEmpty())) {
                                Text(formProblem, style = MaterialTheme.typography.bodySmall, color = VoiidColor.textSecondary)
                            }
                            Button(enabled = formProblem == null && !submitting, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), onClick = {
                                submitting = true; submitError = null
                                scope.launch {
                                    try {
                                        status = service.verify(if (payoutUpi)
                                            KycService.VerifyInput(legalName.trim(), email.trim(), pan, "upi", upi_id = upi)
                                        else KycService.VerifyInput(legalName.trim(), email.trim(), pan, "bank", bank_account = account, ifsc = ifsc))
                                        // The numbers have done their job; don't keep them on screen or in memory.
                                        pan = ""; account = ""; accountAgain = ""; ifsc = ""; upi = ""
                                    } catch (e: CancellationException) { throw e } catch (e: Exception) {
                                        submitError = (e as? ApiError)?.message ?: "Couldn't verify right now. Try again."
                                    } finally { submitting = false }
                                }
                            }) { Text(if (submitting) "Verifying…" else "Verify") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Message(title: String, text: String, tone: Color = VoiidColor.accentInk) {
    Surface(shape = RoundedCornerShape(22.dp), color = VoiidColor.surfaceCard) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = tone)
            Text(text, color = VoiidColor.textSecondary)
        }
    }
}

@Composable
private fun PayoutSummary(v: KycService.Verification) {
    Surface(shape = RoundedCornerShape(22.dp), color = VoiidColor.surfaceCard) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Payout details", style = MaterialTheme.typography.titleMedium)
            Text("${v.legal_name ?: "—"}${v.pan_last4?.let { " · PAN ending $it" } ?: ""}")
            Text(if (v.payout_method == "upi") listOfNotNull("UPI ID", v.upi_masked, v.bank_name).joinToString(" · ")
                 else listOfNotNull(v.bank_name, v.bank_last4?.let { "Account ending $it" }, v.ifsc).joinToString(" · "),
                color = VoiidColor.textSecondary)
        }
    }
}

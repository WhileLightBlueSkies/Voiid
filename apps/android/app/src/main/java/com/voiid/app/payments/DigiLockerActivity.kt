package com.voiid.app.payments

import android.annotation.SuppressLint
import android.app.Activity
import android.net.Uri
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * DigiLocker's own sign-in page, for host Aadhaar verification (routes/kyc.ts). The host types
 * their Aadhaar and OTP there, not in Voiid. The page ends on our return URL, which redirects to
 * `voiid-kyc://return`; that closes this screen and the caller asks the server for the result —
 * the server's answer is what counts, so closing early is harmless. Mirrors iOS, which uses an
 * ASWebAuthenticationSession for the same page.
 */
class DigiLockerActivity : Activity() {
    private var web: WebView? = null
    private var done = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val url = Uri.parse(intent.getStringExtra("url") ?: return finishWith(false))
        // Cashfree's DigiLocker link only, over https.
        if (url.scheme != "https" || url.host?.endsWith("cashfree.com") != true) return finishWith(false)
        val view = WebView(this)
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean =
                if (request.url.scheme == "voiid-kyc") { finishWith(true); true } else false
        }
        web = view
        setContentView(view)
        view.loadUrl(url.toString())
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val view = web
        if (view != null && view.canGoBack()) view.goBack() else finishWith(false)
    }

    override fun onDestroy() {
        web?.destroy(); web = null
        super.onDestroy()
    }

    private fun finishWith(returned: Boolean) {
        if (done) return
        done = true
        setResult(if (returned) RESULT_OK else RESULT_CANCELED)
        finish()
    }
}

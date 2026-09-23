package com.voiid.app.payments

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import com.razorpay.Checkout
import com.razorpay.PaymentResultListener
import org.json.JSONObject

/**
 * Presents the payment provider's checkout. The result is only a checkout hint — ticket
 * issuance stays server-authoritative (the signed webhook), and the caller polls for it.
 *
 * CASHFREE is not an SDK in this app. `checkout_url` is a page on our API that loads Cashfree's
 * own hosted checkout; it opens here in a WebView, which closes when the page redirects to
 * `voiid-pay://return`. UPI (`upi://`, `intent://`) and other non-web links are handed to the
 * phone so the buyer's UPI app opens exactly as it would from a browser. Mirrors iOS
 * `EventCheckoutView`, which uses ASWebAuthenticationSession for the same page.
 */
class EventCheckoutActivity : Activity(), PaymentResultListener {
    private var completed = false
    private var web: WebView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        try {
            val options = JSONObject(intent.getStringExtra("checkout") ?: error("Missing checkout"))
            if (options.optString("provider") == "cashfree") openCashfree(options) else openRazorpay(options)
        } catch (_: Exception) { finishCheckout(false) }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun openCashfree(options: JSONObject) {
        val url = Uri.parse(options.getString("checkout_url"))
        // Only ever our own API's checkout page, over https — never a URL that could send the
        // buyer somewhere else to type card details.
        require(url.scheme == "https" && url.path?.startsWith("/payments/checkout/cashfree/") == true)
        require(options.getLong("amount") > 0)
        val view = WebView(this)
        // Cashfree's checkout is a JavaScript page; storage lets it keep the session across its
        // own redirects (bank OTP pages and back).
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                val target = request.url
                return when (target.scheme) {
                    "voiid-pay" -> { finishCheckout(true); true }
                    "http", "https" -> false
                    else -> {
                        // upi://, intent://, tez:// … — the buyer's payment app, not a page.
                        try {
                            val handoff = if (target.scheme == "intent") Intent.parseUri(target.toString(), Intent.URI_INTENT_SCHEME)
                                          else Intent(Intent.ACTION_VIEW, target)
                            startActivity(handoff)
                        } catch (_: ActivityNotFoundException) {
                        } catch (_: Exception) {}
                        true
                    }
                }
            }
        }
        web = view
        setContentView(view)
        view.loadUrl(url.toString())
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val view = web
        if (view != null && view.canGoBack()) view.goBack() else finishCheckout(false)
    }

    override fun onDestroy() {
        web?.destroy()
        web = null
        super.onDestroy()
    }

    private fun openRazorpay(options: JSONObject) {
        val key = options.getString("key")
        require(key.startsWith("rzp_") && options.getLong("amount") > 0 && options.getString("order_id").startsWith("order_"))
        options.remove("key")
        options.put("name", "Voiid")
        options.put("theme", JSONObject().put("color", "#13828C"))
        Checkout().apply { setKeyID(key); open(this@EventCheckoutActivity, options) }
    }

    override fun onPaymentSuccess(paymentId: String?) { finishCheckout(true) }
    override fun onPaymentError(code: Int, response: String?) { finishCheckout(false) }
    private fun finishCheckout(submitted: Boolean) {
        if (completed) return
        completed = true
        setResult(if (submitted) RESULT_OK else RESULT_CANCELED)
        finish()
    }
}

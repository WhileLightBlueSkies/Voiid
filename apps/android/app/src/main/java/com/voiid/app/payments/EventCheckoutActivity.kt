package com.voiid.app.payments

import android.app.Activity
import android.os.Bundle
import com.razorpay.Checkout
import com.razorpay.PaymentResultListener
import org.json.JSONObject

/** The result is only a checkout hint. Ticket issuance remains server-authoritative. */
class EventCheckoutActivity : Activity(), PaymentResultListener {
    private var completed = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        try {
            val options = JSONObject(intent.getStringExtra("checkout") ?: error("Missing checkout"))
            val key = options.getString("key")
            require(key.startsWith("rzp_") && options.getLong("amount") > 0 && options.getString("order_id").startsWith("order_"))
            options.remove("key")
            options.put("name", "Voiid")
            options.put("theme", JSONObject().put("color", "#13828C"))
            Checkout().apply { setKeyID(key); open(this@EventCheckoutActivity, options) }
        } catch (_: Exception) { finishCheckout(false) }
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

package com.voiid.app.net

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable

/**
 * Client for community events and ticketing (plan item 3.23). Mirrors `EventService.swift`.
 *
 * Like tournaments, the backend shipped complete — events, orders, tickets, rotating QR
 * codes, check-in — and neither app referenced it, so no user could see an event existed.
 *
 * ## Free events only, today
 * `POST /events/:id/orders` answers **501 for a paid event**: the payment provider is not
 * wired up. That is a real, current server state, so this client says so plainly rather than
 * offering an RSVP button that cannot work. When payments land, the paid branch of the same
 * endpoint starts answering and the checkout handoff gets added here.
 *
 * ## What is and is not private
 * An event is server-readable by construction: the server has to hold capacity, orders and
 * check-in state to enforce any of them. It is scoped to the community and gated on
 * membership, but it is NOT end-to-end encrypted, and nothing in this flow implies it is.
 */
class EventService(private val api: ApiClient) {

    /** One event, as the list endpoint returns it. Defaults throughout: a RESPONSE model. */
    @Serializable
    data class Event(
        val id: String,
        val title: String,
        val description: String? = null,
        val starts_at: String? = null,
        val ends_at: String? = null,
        val location_text: String? = null,
        val capacity: Int? = null,
        /** Price in the currency's minor unit (paise, cents). 0 means free. */
        val price_minor: Int? = null,
        val currency: String? = null,
        /** draft | published | cancelled — only `published` takes orders. */
        val status: String? = null,
        val is_free: Boolean? = null,
        /** Your existing order, if any: pending | paid | refunded | cancelled. */
        val your_order_status: String? = null,
    ) {
        /**
         * Trust the server's own verdict when it sends one, and fall back to the price only
         * when it does not — the two cannot disagree, but the server is the authority.
         */
        val free: Boolean get() = is_free ?: ((price_minor ?: 0) == 0)
    }

    @Serializable
    private data class ListResponse(val events: List<Event> = emptyList())

    /**
     * REQUEST body, so the default must be ENCODED. kotlinx omits a field equal to its
     * default unless told otherwise, which has silently broken receipts, Stories and action
     * envelopes in this repo — here it would send `{}` and the server would reject it.
     */
    @OptIn(ExperimentalSerializationApi::class)
    @Serializable
    private data class OrderBody(@EncodeDefault val quantity: Int = 1)

    suspend fun list(communityId: String): List<Event> {
        val raw = api.request("GET", "communities/$communityId/events")
        return ApiClient.json.decodeFromString(ListResponse.serializer(), raw).events
    }

    /**
     * Claim a ticket. Quantity is fixed at 1: multi-ticket ordering is a real server
     * capability (up to 10) but it needs a quantity picker and a paid flow to be worth
     * anything, and neither exists yet.
     */
    suspend fun rsvp(eventId: String) {
        api.request(
            "POST", "events/$eventId/orders",
            jsonBody = ApiClient.json.encodeToString(OrderBody.serializer(), OrderBody()),
        )
    }
}

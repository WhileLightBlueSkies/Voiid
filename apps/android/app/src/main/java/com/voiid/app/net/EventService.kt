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
        val can_manage: Boolean = false,
        val can_checkin: Boolean = false,
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
    suspend fun rsvp(eventId: String, quantity:Int=1): String {
        return api.request(
            "POST", "events/$eventId/orders",
            jsonBody = ApiClient.json.encodeToString(OrderBody.serializer(), OrderBody(quantity)),
        )
    }

    suspend fun orderStatus(eventId: String): String? = org.json.JSONObject(
        api.request("GET", "events/$eventId/my-order")
    ).optJSONObject("order")?.optString("status")

    @Serializable
    data class Earnings(val commission_bps: Int, val totals: List<EarningsTotal>, val payouts_ready: Boolean)
    @Serializable
    data class EarningsTotal(val currency: String, val status: String, val orders: Int,
        val gross_minor: String, val commission_minor: String?, val organiser_minor: String?, val unpriced_orders: Int)
    suspend fun earnings(communityId: String): Earnings = ApiClient.json.decodeFromString(
        Earnings.serializer(), api.request("GET", "communities/$communityId/wallet"))

    @Serializable data class Ticket(val people:Int=1, val id:String,val event_id:String,val state:String,val checked_in_at:String?=null,
        val title:String?=null,val starts_at:String?=null,val location_text:String?=null,val event_status:String?=null,val order_status:String?=null)
    @Serializable private data class Tickets(val tickets:List<Ticket>)
    @Serializable data class TicketCode(val code:String,val expires_at:Long)
    suspend fun tickets():List<Ticket> = ApiClient.json.decodeFromString(Tickets.serializer(),api.request("GET","my/event-tickets")).tickets
    suspend fun ticketCode(id:String):TicketCode = ApiClient.json.decodeFromString(TicketCode.serializer(),api.request("GET","event-tickets/$id/code"))
    @Serializable data class HostOrder(val id:String,val full_name:String?=null,val username:String?=null,val quantity:Int,val status:String,val checked_in:Int=0,
        val amount_minor:Int?=null,val currency:String?=null,
        /** A refund on its way, why, and why it failed if it did (094). Twin of iOS `Order`. */
        val refund_requested_at:String?=null,val refund_reason:String?=null,val refund_error:String?=null) {
        val display:String get() = full_name?.takeIf{it.isNotBlank()} ?: username?.takeIf{it.isNotBlank()}?.let{"@$it"} ?: "Someone"
        /** Paid and took money, and no refund already on its way (or the last one failed). */
        val canRefund:Boolean get() = status=="paid" && (amount_minor ?: 0) > 0 && (refund_requested_at==null || refund_error!=null)
    }
    @Serializable private data class RefundBody(@EncodeDefault val refund:Boolean=true,val reason:String)
    @Serializable private data class RefundCounts(val requested:Int=0,val failed:Int=0)
    @Serializable private data class CancelRefundResponse(val refunds:RefundCounts?=null)
    /** Cancel AND refund every paid order — an explicit choice, never the default. (requested, failed). */
    @OptIn(ExperimentalSerializationApi::class)
    suspend fun cancelAndRefund(id:String,reason:String="event_cancelled"):Pair<Int,Int> {
        val r=ApiClient.json.decodeFromString(CancelRefundResponse.serializer(),
            api.request("POST","events/$id/cancel",jsonBody=ApiClient.json.encodeToString(RefundBody.serializer(),RefundBody(reason=reason))))
        return (r.refunds?.requested ?: 0) to (r.refunds?.failed ?: 0)
    }
    @Serializable private data class ReasonBody(val reason:String)
    suspend fun refundOrder(id:String,orderId:String,reason:String) {
        api.request("POST","events/$id/orders/$orderId/refund",jsonBody=ApiClient.json.encodeToString(ReasonBody.serializer(),ReasonBody(reason)))
    }
    @Serializable private data class Orders(val orders:List<HostOrder>)
    suspend fun orders(id:String):List<HostOrder> = ApiClient.json.decodeFromString(Orders.serializer(),api.request("GET","events/$id/orders")).orders
    suspend fun transition(id:String,action:String) { require(action in listOf("publish","cancel"));api.request("POST","events/$id/$action") }
    @Serializable private data class CheckBody(val code:String)
    @Serializable data class CheckResult(val ok:Boolean,val people:Int=1,val holder_name:String?=null,val checked_in_at:String?=null)
    suspend fun checkIn(id:String,code:String):CheckResult = ApiClient.json.decodeFromString(CheckResult.serializer(),
        api.request("POST","events/$id/check-in",jsonBody=ApiClient.json.encodeToString(CheckBody.serializer(),CheckBody(code))))

    @OptIn(ExperimentalSerializationApi::class)
    @Serializable data class EventDraft(val title:String,val description:String,val starts_at:String,@EncodeDefault val ends_at:String?=null,
        val location_text:String,@EncodeDefault val capacity:Int?=null,val price_minor:Int=0,val currency:String="INR",val publish:Boolean=false)
    suspend fun create(communityId:String,draft:EventDraft) {api.request("POST","communities/$communityId/events",jsonBody=ApiClient.json.encodeToString(EventDraft.serializer(),draft))}
    suspend fun edit(eventId:String,draft:EventDraft) {api.request("PATCH","events/$eventId",jsonBody=ApiClient.json.encodeToString(EventDraft.serializer(),draft))}

    @Serializable data class StaffInvite(val event_id:String,val title:String,val role:String,val state:String,val expires_at:String)
    @Serializable private data class Invitations(val invitations:List<StaffInvite>)
    @Serializable data class StaffMember(val user_id:String,val full_name:String?=null,val username:String?=null,val role:String,val state:String,val expires_at:String)
    @Serializable private data class Team(val staff:List<StaffMember>)
    @Serializable private data class InviteBody(val username:String,val role:String)
    suspend fun invitations(communityId:String):List<StaffInvite> = ApiClient.json.decodeFromString(Invitations.serializer(),api.request("GET","communities/$communityId/staff-invitations")).invitations
    suspend fun acceptInvite(id:String){api.request("POST","events/$id/team/accept")}
    suspend fun team(id:String):List<StaffMember> = ApiClient.json.decodeFromString(Team.serializer(),api.request("GET","events/$id/team")).staff
    suspend fun invite(id:String,username:String,role:String){api.request("POST","events/$id/team",jsonBody=ApiClient.json.encodeToString(InviteBody.serializer(),InviteBody(username,role)))}
    suspend fun removeStaff(id:String,userId:String){api.request("DELETE","events/$id/team/$userId")}
}

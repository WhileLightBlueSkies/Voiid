package com.voiid.app.model

/** Models for group info + 1:1 contact profile (dummy phase) — port of iOS `GroupModels.swift`. */

enum class MemberRole { ADMIN, MEMBER }

data class VMember(
    val id: String,
    var name: String,
    var phone: String,
    var photoName: String? = null,
    var role: MemberRole = MemberRole.MEMBER,
    var statusText: String? = null,
    var isYou: Boolean = false,
)

/** Shared media/links/docs item shown in group info / contact profile. */
data class VMediaItem(
    val id: String,
    val kind: Kind,
    var title: String = "",
) {
    enum class Kind { PHOTO, VIDEO, LINK, DOC }
}

/** Standout group feature: in-chat poll. */
data class VPoll(
    val id: String,
    var question: String,
    var options: List<Option>,
) {
    data class Option(val id: String, var text: String, var votes: Int)
    val totalVotes: Int get() = options.sumOf { it.votes }
}

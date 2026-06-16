package com.voiid.app.model

/**
 * Sample data for the dummy-frontend phase — port of iOS `DummyData.swift`.
 * Names match the Figma mockups (Priyanshu, Nehal, Sampath, Michael Lingston, …).
 */
object DummyData {
    private fun now() = System.currentTimeMillis()

    val me = VUser(id = "me", fullName = "You", phoneNumber = "+91 91234 56789")

    val users: List<VUser> = listOf(
        VUser(id = "u1", fullName = "Priyanshu", phoneNumber = "+91 90000 00001", isOnline = true),
        VUser(id = "u2", fullName = "Nehal", phoneNumber = "+91 90000 00002", isOnline = true),
        VUser(id = "u3", fullName = "Sampath", phoneNumber = "+91 90000 00003"),
        VUser(id = "u4", fullName = "Michael Lingston", phoneNumber = "+91 90000 00004", statusText = "Online", isOnline = true),
    )

    val directConversations: List<VConversation>
        get() = listOf(
            VConversation(id = "c1", type = ConversationType.DIRECT, title = "Priyanshu", lastMessagePreview = "Yoooo", lastMessageAt = now(), unreadCount = 2, isOnline = true),
            VConversation(id = "c2", type = ConversationType.DIRECT, title = "Nehal", lastMessagePreview = "Whats good?", lastMessageAt = now(), isOnline = true),
            VConversation(id = "c3", type = ConversationType.DIRECT, title = "Sampath", lastMessagePreview = "See you tomorrow", lastMessageAt = now()),
            VConversation(id = "c4", type = ConversationType.DIRECT, title = "Michael Lingston", lastMessagePreview = "YooYooooo", lastMessageAt = now(), isOnline = true),
        )

    val groupConversations: List<VConversation>
        get() = listOf(
            VConversation(id = "g1", type = ConversationType.GROUP, title = "Group Name", lastMessagePreview = "Heyyyyy", lastMessageAt = now(), memberCount = 4),
            VConversation(id = "g2", type = ConversationType.GROUP, title = "Team Voiid", lastMessagePreview = "Ship it", lastMessageAt = now(), memberCount = 6),
        )

    fun messages(conversationId: String): List<VMessage> = listOf(
        VMessage(id = "m1", conversationId = conversationId, senderId = "u4", text = "Whats good? How can i Help you today?", createdAt = now(), isMine = false),
        VMessage(id = "m2", conversationId = conversationId, senderId = "me", text = "Yoooo", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "m3", conversationId = conversationId, senderId = "u4", text = "Whats good? How can i Help you today?", createdAt = now(), isMine = false),
        VMessage(id = "m4", conversationId = conversationId, senderId = "me", text = "YooYooooo", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "m5", conversationId = conversationId, senderId = "u4", text = "Whats good? How can i Help you today?", createdAt = now(), isMine = false),
    )

    // Group conversation messages — sender names + a system message.
    fun groupMessages(conversationId: String): List<VMessage> = listOf(
        VMessage(id = "gm0", conversationId = conversationId, senderId = "system", kind = MessageKind.SYSTEM, text = "You added Priyanshu, Nehal and Sampath", createdAt = now(), isMine = false),
        VMessage(id = "gm1", conversationId = conversationId, senderId = "u1", senderName = "Priyanshu", text = "Hey team 👋", createdAt = now(), isMine = false),
        VMessage(id = "gm2", conversationId = conversationId, senderId = "u2", senderName = "Nehal", text = "Whats good? How can i Help you today?", createdAt = now(), isMine = false),
        VMessage(id = "gm3", conversationId = conversationId, senderId = "me", text = "Yoooo", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "gm4", conversationId = conversationId, senderId = "u3", senderName = "Sampath", text = "On my way", createdAt = now(), isMine = false),
    )

    val groupMembers: List<VMember> = listOf(
        VMember(id = "me", name = "You", phone = "+91 91234 56789", role = MemberRole.ADMIN, isYou = true),
        VMember(id = "u1", name = "Priyanshu", phone = "+91 90000 00001", role = MemberRole.ADMIN),
        VMember(id = "u2", name = "Nehal", phone = "+91 90000 00002", statusText = "Available"),
        VMember(id = "u3", name = "Sampath", phone = "+91 90000 00003", statusText = "Busy"),
    )

    val sharedMedia: List<VMediaItem> = (1..9).map { VMediaItem(id = "media$it", kind = VMediaItem.Kind.PHOTO) }

    val groupPoll = VPoll(
        id = "poll1", question = "Where to meet this weekend?",
        options = listOf(
            VPoll.Option("o1", "Cafe", 3),
            VPoll.Option("o2", "Beach", 5),
            VPoll.Option("o3", "Home", 1),
        ),
    )

    val clips: List<VClip> = listOf(
        VClip(id = "cl1", authorName = "Michael Lingston", heading = "Clip's Heading or main caption", caption = "Clip's sub caption or descriptions........", likes = 50000, comments = 1000),
        VClip(id = "cl2", authorName = "Priyanshu", heading = "Another great clip", caption = "Short form vibes", likes = 1200, comments = 45),
    )

    val clipComments: List<VClipComment> = listOf(
        VClipComment(id = "cc1", authorName = "Michael Lingston", text = "Well typical internet comment hahahahhahaha"),
        VClipComment(id = "cc2", authorName = "Nehal", text = "🔥🔥🔥"),
    )

    val aiMessages: List<VAIMessage> = listOf(
        VAIMessage(id = "ai1", text = "Whats good? How can i Help you today?", isUser = false),
        VAIMessage(id = "ai2", text = "Yoooo", isUser = true),
        VAIMessage(id = "ai3", text = "YooYooooo", isUser = true),
    )
}

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
            VConversation(id = "c5", type = ConversationType.DIRECT, title = "Aarav", lastMessagePreview = "Call me later", lastMessageAt = now(), unreadCount = 1),
            VConversation(id = "c6", type = ConversationType.DIRECT, title = "Diya", lastMessagePreview = "😂😂", lastMessageAt = now(), isOnline = true),
            VConversation(id = "c7", type = ConversationType.DIRECT, title = "Kabir", lastMessagePreview = "Sent the files", lastMessageAt = now()),
            VConversation(id = "c8", type = ConversationType.DIRECT, title = "Ananya", lastMessagePreview = "Thank you!", lastMessageAt = now(), unreadCount = 5),
            VConversation(id = "c9", type = ConversationType.DIRECT, title = "Vivaan", lastMessagePreview = "👍", lastMessageAt = now()),
            VConversation(id = "c10", type = ConversationType.DIRECT, title = "Ishaan", lastMessagePreview = "On my way", lastMessageAt = now(), isOnline = true),
            VConversation(id = "c11", type = ConversationType.DIRECT, title = "Saanvi", lastMessagePreview = "Let's catch up", lastMessageAt = now()),
            VConversation(id = "c12", type = ConversationType.DIRECT, title = "Reyansh", lastMessagePreview = "Done ✅", lastMessageAt = now(), unreadCount = 3),
            VConversation(id = "c13", type = ConversationType.DIRECT, title = "Aadhya", lastMessagePreview = "Where are you?", lastMessageAt = now(), isOnline = true),
            VConversation(id = "c14", type = ConversationType.DIRECT, title = "Arjun", lastMessagePreview = "Haha true", lastMessageAt = now()),
            VConversation(id = "c15", type = ConversationType.DIRECT, title = "Myra", lastMessagePreview = "See you soon", lastMessageAt = now()),
            VConversation(id = "c16", type = ConversationType.DIRECT, title = "Aditya", lastMessagePreview = "📷 Photo", lastMessageAt = now(), isOnline = true),
            VConversation(id = "c17", type = ConversationType.DIRECT, title = "Kiara", lastMessagePreview = "Good night 🌙", lastMessageAt = now()),
            VConversation(id = "c18", type = ConversationType.DIRECT, title = "Rohan", lastMessagePreview = "Let me check", lastMessageAt = now(), unreadCount = 1),
        )

    val groupConversations: List<VConversation>
        get() = listOf(
            VConversation(id = "g1", type = ConversationType.GROUP, title = "Group Name", lastMessagePreview = "Heyyyyy", lastMessageAt = now(), memberCount = 4),
            VConversation(id = "g2", type = ConversationType.GROUP, title = "Team Voiid", lastMessagePreview = "Ship it", lastMessageAt = now(), memberCount = 6),
            VConversation(id = "g3", type = ConversationType.GROUP, title = "Family", lastMessagePreview = "Dinner at 8?", lastMessageAt = now(), unreadCount = 4, memberCount = 5),
            VConversation(id = "g4", type = ConversationType.GROUP, title = "College Buddies", lastMessagePreview = "Reunion plans 🎉", lastMessageAt = now(), memberCount = 12),
            VConversation(id = "g5", type = ConversationType.GROUP, title = "Weekend Trip", lastMessagePreview = "Booked the cab", lastMessageAt = now(), unreadCount = 2, memberCount = 7),
            VConversation(id = "g6", type = ConversationType.GROUP, title = "Project Alpha", lastMessagePreview = "Standup at 10", lastMessageAt = now(), memberCount = 9),
        )

    fun messages(conversationId: String): List<VMessage> = listOf(
        VMessage(id = "m1", conversationId = conversationId, senderId = "u4", text = "Whats good? How can i Help you today?", createdAt = now(), isMine = false),
        VMessage(id = "m2", conversationId = conversationId, senderId = "me", text = "Yoooo", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "m3", conversationId = conversationId, senderId = "u4", text = "Did you get a chance to look at the designs?", createdAt = now(), isMine = false),
        VMessage(id = "m4", conversationId = conversationId, senderId = "me", text = "Yep! Looks 🔥 honestly", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "m5", conversationId = conversationId, senderId = "me", text = "Just the spacing on the cards felt a bit tight", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "m6", conversationId = conversationId, senderId = "u4", text = "Good catch, fixing that now", createdAt = now(), isMine = false),
        VMessage(id = "m7", conversationId = conversationId, senderId = "u4", kind = MessageKind.VOICE, text = "🎤 Voice message · 8s", createdAt = now(), isMine = false),
        VMessage(id = "m8", conversationId = conversationId, senderId = "me", text = "Perfect, ship it 🚀", createdAt = now(), status = MessageStatus.DELIVERED, isMine = true),
    )

    // Group conversation messages — sender names + a system message + a poll.
    fun groupMessages(conversationId: String): List<VMessage> = listOf(
        VMessage(id = "gm0", conversationId = conversationId, senderId = "system", kind = MessageKind.SYSTEM, text = "You added Priyanshu, Nehal and Sampath", createdAt = now(), isMine = false),
        VMessage(id = "gm1", conversationId = conversationId, senderId = "u1", senderName = "Priyanshu", text = "Hey team 👋", createdAt = now(), isMine = false),
        VMessage(id = "gm2", conversationId = conversationId, senderId = "u2", senderName = "Nehal", text = "Whats good? How can i Help you today?", createdAt = now(), isMine = false),
        VMessage(id = "gm3", conversationId = conversationId, senderId = "me", text = "Hey all 👋 welcome!", createdAt = now(), status = MessageStatus.READ, isMine = true),
        VMessage(id = "gm4", conversationId = conversationId, senderId = "u3", senderName = "Sampath", text = "Excited to be here", createdAt = now(), isMine = false),
        VMessage(id = "gm5", conversationId = conversationId, senderId = "u1", senderName = "Priyanshu", text = "When are we meeting this weekend?", createdAt = now(), isMine = false),
        VMessage(id = "gm6", conversationId = conversationId, senderId = "me", text = "Let's do Saturday evening", createdAt = now(), status = MessageStatus.DELIVERED, isMine = true),
        VMessage(id = "gm7", conversationId = conversationId, senderId = "u2", senderName = "Nehal", text = "Works for me 👍", createdAt = now(), isMine = false),
        VMessage(id = "gm8", conversationId = conversationId, senderId = "u1", senderName = "Priyanshu", kind = MessageKind.POLL, text = "Poll", createdAt = now(), isMine = false, poll = groupPoll),
    )

    val groupMembers: List<VMember> = listOf(
        VMember(id = "me", name = "You", phone = "+91 91234 56789", role = MemberRole.ADMIN, isYou = true),
        VMember(id = "u1", name = "Priyanshu", phone = "+91 90000 00001", role = MemberRole.ADMIN),
        VMember(id = "u2", name = "Nehal", phone = "+91 90000 00002", statusText = "Available"),
        VMember(id = "u3", name = "Sampath", phone = "+91 90000 00003", statusText = "Busy"),
    )

    val sharedMedia: List<VMediaItem> = (1..9).map { VMediaItem(id = "media$it", kind = VMediaItem.Kind.PHOTO) }

    // Full shared-media set split by type (for the "See all" sheet).
    val sharedPhotos: List<VMediaItem> = (1..12).map { VMediaItem(id = "p$it", kind = VMediaItem.Kind.PHOTO) }
    val sharedVideos: List<VMediaItem> = (1..5).map { VMediaItem(id = "v$it", kind = VMediaItem.Kind.VIDEO, title = "0:${10 + it}") }
    val sharedVoice: List<VMediaItem> = (1..4).map { VMediaItem(id = "a$it", kind = VMediaItem.Kind.LINK, title = "Voice · 0:${8 + it}") }
    val sharedDocs: List<VMediaItem> = listOf(
        VMediaItem(id = "d1", kind = VMediaItem.Kind.DOC, title = "Design Spec.pdf"),
        VMediaItem(id = "d2", kind = VMediaItem.Kind.DOC, title = "Budget.xlsx"),
        VMediaItem(id = "d3", kind = VMediaItem.Kind.DOC, title = "Notes.txt"),
    )

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

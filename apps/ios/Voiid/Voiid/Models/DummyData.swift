//
//  DummyData.swift
//  Voiid
//
//  Sample data for the dummy-frontend phase. Names match the Figma mockups
//  (Priyanshu, Nehal, Sampath, Michael Lingston, etc.). Replaced by real backend
//  data once messaging is wired.
//

import Foundation

enum DummyData {
    static let me = VUser(id: "me", fullName: "You", phoneNumber: "+91 91234 56789")

    static let users: [VUser] = [
        VUser(id: "u1", fullName: "Priyanshu", phoneNumber: "+91 90000 00001", isOnline: true),
        VUser(id: "u2", fullName: "Nehal", phoneNumber: "+91 90000 00002", isOnline: true),
        VUser(id: "u3", fullName: "Sampath", phoneNumber: "+91 90000 00003"),
        VUser(id: "u4", fullName: "Michael Lingston", phoneNumber: "+91 90000 00004", statusText: "Online", isOnline: true),
    ]

    static let directConversations: [VConversation] = [
        VConversation(id: "c1", type: .direct, title: "Priyanshu", lastMessagePreview: "Yoooo", lastMessageAt: .now, unreadCount: 2, isOnline: true),
        VConversation(id: "c2", type: .direct, title: "Nehal", lastMessagePreview: "Whats good?", lastMessageAt: .now, isOnline: true),
        VConversation(id: "c3", type: .direct, title: "Sampath", lastMessagePreview: "See you tomorrow", lastMessageAt: .now),
        VConversation(id: "c4", type: .direct, title: "Michael Lingston", lastMessagePreview: "YooYooooo", lastMessageAt: .now, isOnline: true),
    ]

    static let groupConversations: [VConversation] = [
        VConversation(id: "g1", type: .group, title: "Group Name", lastMessagePreview: "Heyyyyy", lastMessageAt: .now, memberCount: 4),
        VConversation(id: "g2", type: .group, title: "Team Voiid", lastMessagePreview: "Ship it", lastMessageAt: .now, memberCount: 6),
    ]

    static func messages(for conversationId: String) -> [VMessage] {
        [
            VMessage(id: "m1", conversationId: conversationId, senderId: "u4", text: "Whats good? How can i Help you today?", createdAt: .now, isMine: false),
            VMessage(id: "m2", conversationId: conversationId, senderId: "me", text: "Yoooo", createdAt: .now, status: .read, isMine: true),
            VMessage(id: "m3", conversationId: conversationId, senderId: "u4", text: "Did you get a chance to look at the designs?", createdAt: .now, isMine: false),
            VMessage(id: "m4", conversationId: conversationId, senderId: "me", text: "Yep! Looks 🔥 honestly", createdAt: .now, status: .read, isMine: true),
            VMessage(id: "m5", conversationId: conversationId, senderId: "me", text: "Just the spacing on the cards felt a bit tight", createdAt: .now, status: .read, isMine: true),
            VMessage(id: "m6", conversationId: conversationId, senderId: "u4", text: "Good catch, fixing that now", createdAt: .now, isMine: false),
            VMessage(id: "m7", conversationId: conversationId, senderId: "u4", kind: .voice, text: "🎤 Voice message · 8s", createdAt: .now, isMine: false),
            VMessage(id: "m8", conversationId: conversationId, senderId: "me", text: "Perfect, ship it 🚀", createdAt: .now, status: .delivered, isMine: true),
        ]
    }

    // Group conversation messages — sender names + a system message.
    static func groupMessages(for conversationId: String) -> [VMessage] {
        [
            VMessage(id: "gm0", conversationId: conversationId, senderId: "system",
                     kind: .system, text: "You added Priyanshu, Nehal and Sampath", createdAt: .now, isMine: false),
            VMessage(id: "gm1", conversationId: conversationId, senderId: "u1", senderName: "Priyanshu",
                     text: "Hey team 👋", createdAt: .now, isMine: false),
            VMessage(id: "gm2", conversationId: conversationId, senderId: "u2", senderName: "Nehal",
                     text: "Whats good? How can i Help you today?", createdAt: .now, isMine: false),
            VMessage(id: "gm3", conversationId: conversationId, senderId: "me",
                     text: "Hey all 👋 welcome!", createdAt: .now, status: .read, isMine: true),
            VMessage(id: "gm4", conversationId: conversationId, senderId: "u3", senderName: "Sampath",
                     text: "Excited to be here", createdAt: .now, isMine: false),
            VMessage(id: "gm5", conversationId: conversationId, senderId: "u1", senderName: "Priyanshu",
                     text: "When are we meeting this weekend?", createdAt: .now, isMine: false),
            VMessage(id: "gm6", conversationId: conversationId, senderId: "me",
                     text: "Let's do Saturday evening", createdAt: .now, status: .delivered, isMine: true),
            VMessage(id: "gm7", conversationId: conversationId, senderId: "u2", senderName: "Nehal",
                     text: "Works for me 👍", createdAt: .now, isMine: false),
        ]
    }

    static let groupMembers: [VMember] = [
        VMember(id: "me", name: "You", phone: "+91 91234 56789", role: .admin, isYou: true),
        VMember(id: "u1", name: "Priyanshu", phone: "+91 90000 00001", role: .admin),
        VMember(id: "u2", name: "Nehal", phone: "+91 90000 00002", statusText: "Available"),
        VMember(id: "u3", name: "Sampath", phone: "+91 90000 00003", statusText: "Busy"),
    ]

    static let sharedMedia: [VMediaItem] = (1...9).map {
        VMediaItem(id: "media\($0)", kind: .photo, title: "")
    }

    static let groupPoll = VPoll(id: "poll1", question: "Where to meet this weekend?", options: [
        .init(id: "o1", text: "Cafe", votes: 3),
        .init(id: "o2", text: "Beach", votes: 5),
        .init(id: "o3", text: "Home", votes: 1),
    ])

    static let clips: [VClip] = [
        VClip(id: "cl1", authorName: "Michael Lingston", heading: "Clip's Heading or main caption", caption: "Clip's sub caption or descriptions........", likes: 50000, comments: 1000),
        VClip(id: "cl2", authorName: "Priyanshu", heading: "Another great clip", caption: "Short form vibes", likes: 1200, comments: 45),
    ]

    static let clipComments: [VClipComment] = [
        VClipComment(id: "cc1", authorName: "Michael Lingston", text: "Well typical internet comment hahahahhahaha"),
        VClipComment(id: "cc2", authorName: "Nehal", text: "🔥🔥🔥"),
    ]

    static let aiMessages: [VAIMessage] = [
        VAIMessage(id: "ai1", text: "Whats good? How can i Help you today?", isUser: false),
        VAIMessage(id: "ai2", text: "Yoooo", isUser: true),
        VAIMessage(id: "ai3", text: "YooYooooo", isUser: true),
    ]
}

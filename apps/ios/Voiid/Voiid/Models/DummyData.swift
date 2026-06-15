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
            VMessage(id: "m3", conversationId: conversationId, senderId: "u4", text: "Whats good? How can i Help you today?", createdAt: .now, isMine: false),
            VMessage(id: "m4", conversationId: conversationId, senderId: "me", text: "YooYooooo", createdAt: .now, status: .read, isMine: true),
            VMessage(id: "m5", conversationId: conversationId, senderId: "u4", text: "Whats good? How can i Help you today?", createdAt: .now, isMine: false),
        ]
    }

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

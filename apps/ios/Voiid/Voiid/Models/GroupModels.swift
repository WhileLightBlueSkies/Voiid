//
//  GroupModels.swift
//  Voiid
//
//  Models for group info + 1:1 contact profile (dummy phase).
//

import Foundation

enum MemberRole: String { case admin, member }

struct VMember: Identifiable, Hashable {
    let id: String          // user id
    var name: String
    var phone: String
    var photoName: String?
    var role: MemberRole = .member
    var statusText: String?
    var isYou: Bool = false
}

/// Shared media/links/docs item shown in group info / contact profile.
struct VMediaItem: Identifiable, Hashable {
    let id: String
    enum Kind { case photo, video, link, doc }
    var kind: Kind
    var title: String           // doc name / link host / "" for photos
}

/// Standout group feature: in-chat poll.
struct VPoll: Identifiable, Hashable {
    let id: String
    var question: String
    var options: [Option]
    struct Option: Identifiable, Hashable { let id: String; var text: String; var votes: Int }
    var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }
}

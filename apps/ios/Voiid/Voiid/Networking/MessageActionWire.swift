//
//  MessageActionWire.swift
//  Voiid
//
//  Wire types for in-conversation ACTIONS that travel as E2EE messages: reactions,
//  delete-for-everyone, replies, and media forwards. This file is deliberately
//  standalone (no ChatEngine internals) so it compiles independently; the senders and
//  the inbound hook live in ChatEngine.swift, which encrypts these envelopes with the
//  same per-recipient-device fan-out every other message uses.
//
//  WHY: react()/deleteMessage() used to mutate in-memory UI state and nothing else —
//  the peer never saw a reaction, a "delete for everyone" deleted nothing anywhere
//  else, and nothing survived a relaunch. These envelopes make the actions REAL: they
//  ride the existing E2EE path (server sees only opaque ciphertext + a content_type
//  routing hint), exactly the pattern story replies proved out (StoryReplyEnvelope).
//
//  Discriminators follow the established `"t"` probe convention in
//  ChatEngine.decodeEnvelope — any new envelope MUST be added there too, or its raw
//  JSON renders in a bubble on old builds. `v` is the envelope version.
//

import Foundation

/// A reaction to (or un-reaction from) a specific message.
///
/// `emoji == nil` clears the sender's previous reaction — toggling off is an explicit
/// signal, not an absence, so an offline peer converges to the same state.
/// `target` is the SERVER message id (the one both sides share; local ids differ).
struct MessageReactionEnvelope: Codable {
    var t: String = "msg_reaction"
    var v: Int = 1
    let target: String
    let emoji: String?
}

/// Delete-for-everyone: the sender asks every recipient to tombstone `target`.
/// Only ever honoured when the envelope's (authenticated) sender is the message's
/// original author — receivers MUST enforce that, or anyone could erase anyone.
struct MessageDeleteEnvelope: Codable {
    var t: String = "msg_delete"
    var v: Int = 1
    let target: String
}

/// A text message that quotes another. Replaces a bare-text send only when a quote is
/// attached; plain sends stay plain (older builds keep rendering them).
struct MessageReplyEnvelope: Codable {
    var t: String = "msg_reply"
    var v: Int = 1
    let text: String
    /// Server id of the quoted message, plus a short display snippet so the quote
    /// renders even if the recipient no longer has the original (deleted/cleared).
    let quotedId: String
    let quotedPreview: String
    let quotedSender: String
}

/// Media forward envelope — same shape as ChatEngine's private MediaEnvelope, declared
/// here so the forward path can re-send an EXISTING MediaRef without re-uploading the
/// blob: the ciphertext already sits in R2 and the key travels E2EE as always. It
/// serializes identically, so receivers decode it as a normal media message.
struct ForwardedMediaEnvelope: Codable {
    var v: Int = 1
    let media: MediaRef
    let caption: String
}

/// The `content_type` hints these ride under on POST /messages/send. Routing metadata
/// only — the server cannot read the payload; the hint just lets clients decode without
/// trial-parsing every envelope type.
enum MessageActionContentType {
    static let reaction = "msg_reaction"
    static let delete = "msg_delete"
    static let reply = "msg_reply"
    static let media = "media"          // forwards reuse the normal media type
}

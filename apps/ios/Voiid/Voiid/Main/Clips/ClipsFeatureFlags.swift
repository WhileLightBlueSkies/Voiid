//
//  ClipsFeatureFlags.swift
//  Voiid
//
//  Compile-time switches for Clips surfaces that are BUILT but not shown yet.
//
//  These are not dead code and not commented-out code. Everything behind a flag here is
//  fully wired — schema, API, layout — and still compiles on every build, so it cannot
//  silently rot the way commented blocks do. Turning a surface on is a one-line change.
//
//  `static let` (not a UserDefaults read) on purpose: these are product decisions about
//  what ships, not per-user preferences. A user toggle would imply the surface is
//  supported and supportable, which is exactly what is being deferred.
//

import Foundation

enum ClipsFeatureFlags {

    /// Followers / Following counts on a creator profile.
    ///
    /// Hidden for launch. The counts are real (`creator_profiles.follower_count` /
    /// `following_count`, maintained by the follow endpoints) and the row renders them
    /// correctly — but a public follower number on a network this young reads as
    /// "nobody is here", and it is the one number a creator cannot un-see. Clips count
    /// stays: it describes the work, not the audience.
    ///
    /// Flip to `true` when there is enough of a network that the number helps rather
    /// than discourages. Nothing else needs changing.
    static let showSocialCounts = false
}

package com.voiid.app.model

/** Authoritative list membership, independent of retained encrypted transcripts. */
internal object GroupListMembership {
    fun reconcile(
        beforeRefresh: Set<String>,
        current: Set<String>,
        serverGroups: Set<String>,
        communityChannels: Set<String>,
    ): Set<String> = (serverGroups - communityChannels) + ((current - beforeRefresh) - communityChannels)
}

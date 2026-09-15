package com.voiid.app

import com.voiid.app.model.GroupListMembership
import org.junit.Assert.assertEquals
import org.junit.Test

class GroupListMembershipTest {
    @Test fun `ten community channels and four deleted groups leave Groups empty`() {
        val channels = (1..10).map { "channel-$it" }.toSet()
        val deleted = (1..4).map { "deleted-$it" }.toSet()
        assertEquals(emptySet<String>(), GroupListMembership.reconcile(deleted, deleted, channels, channels))
    }

    @Test fun `standalone groups survive alongside community channels`() {
        assertEquals(setOf("group"), GroupListMembership.reconcile(emptySet(), emptySet(), setOf("group", "channel"), setOf("channel")))
    }

    @Test fun `older refresh preserves a newly created group but removes deleted groups`() {
        assertEquals(setOf("new"), GroupListMembership.reconcile(setOf("deleted"), setOf("deleted", "new"), emptySet(), emptySet()))
    }

    @Test fun `channel classification takes precedence over concurrent additions`() {
        assertEquals(emptySet<String>(), GroupListMembership.reconcile(emptySet(), setOf("channel"), setOf("channel"), setOf("channel")))
    }

    @Test fun `empty successful refresh clears the previous list`() {
        assertEquals(emptySet<String>(), GroupListMembership.reconcile(setOf("old"), setOf("old"), emptySet(), emptySet()))
    }
}

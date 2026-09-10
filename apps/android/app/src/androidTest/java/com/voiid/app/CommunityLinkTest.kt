package com.voiid.app

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.voiid.app.net.CommunityLink
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CommunityLinkTest {
    @Test fun communityInvitesRejectAmbiguousAndForeignUrls() {
        val token = "a".repeat(43)
        listOf("https://voiid.app/c/voiid_jobs", "https://www.voiid.app:443/c/voiid_feedback?i=$token", "https://voiid.app/c/VOIID_UPDATES").forEach {
            assertNotNull(it, CommunityLink.parse(Uri.parse(it)))
        }
        listOf("http://voiid.app/c/voiid_jobs", "https://voiid.app.evil.test/c/voiid_jobs", "https://evil.test/c/voiid_jobs", "https://u@voiid.app/c/voiid_jobs", "https://voiid.app:444/c/voiid_jobs", "https://voiid.app/c/voiid_jobs#anything", "https://voiid.app/c/../users", "https://voiid.app/c/%2e%2e%2fusers", "https://voiid.app/c/voiid_jobs?i=bad", "https://voiid.app/c/voiid_jobs?i", "https://voiid.app/c/voiid_jobs?i=", "https://voiid.app/c/voiid_jobs?i=$token&i=$token", "voiid://c/voiid_jobs").forEach {
            assertNull(it, CommunityLink.parse(Uri.parse(it)))
        }
        val link = CommunityLink.parse(Uri.parse(CommunityLink.format("voiid_jobs", token)))
        assertEquals(token, link?.inviteToken)
    }
}

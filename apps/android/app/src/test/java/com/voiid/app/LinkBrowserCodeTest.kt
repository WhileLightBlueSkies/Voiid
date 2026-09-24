package com.voiid.app

import com.voiid.app.net.LinkBrowserCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The scanner acts ONLY on Voiid's own linking payload — never an arbitrary scanned URL. */
class LinkBrowserCodeTest {
    private val token = "Abcdefghij_klmnopqrstuvwxyz-0123"   // 32 url-safe chars

    @Test fun acceptsTheCompanionPayload() =
        assertEquals(token, LinkBrowserCode.token("voiid://link?token=$token"))

    @Test fun rejectsOtherSchemesAndHosts() {
        assertNull(LinkBrowserCode.token("https://link?token=$token"))
        assertNull(LinkBrowserCode.token("voiid://evil?token=$token"))
    }

    @Test fun rejectsExtrasThatCouldSmuggleIntent() {
        assertNull(LinkBrowserCode.token("voiid://user@link?token=$token"))
        assertNull(LinkBrowserCode.token("voiid://link:8080?token=$token"))
        assertNull(LinkBrowserCode.token("voiid://link/path?token=$token"))
        assertNull(LinkBrowserCode.token("voiid://link?token=$token#frag"))
        assertNull(LinkBrowserCode.token("voiid://link?token=$token&next=https://evil"))
    }

    @Test fun rejectsMalformedTokens() {
        assertNull(LinkBrowserCode.token("voiid://link?token=short"))
        assertNull(LinkBrowserCode.token("voiid://link?token=${token.dropLast(1)}!"))
        assertNull(LinkBrowserCode.token("voiid://link?code=$token"))
        assertNull(LinkBrowserCode.token("not a url at all"))
    }
}

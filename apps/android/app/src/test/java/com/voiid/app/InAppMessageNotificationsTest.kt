package com.voiid.app

import com.voiid.app.net.AppPresence
import com.voiid.app.net.DeepLinkRouter
import com.voiid.app.net.InAppMessageNotifications
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class InAppMessageNotificationsTest {
    @Before fun setup() { AppPresence.setForeground(true); AppPresence.setOpenConversation(null); InAppMessageNotifications.clear() }
    @After fun cleanup() { AppPresence.setForeground(false); DeepLinkRouter.pendingConversation.value = null; DeepLinkRouter.pendingMessage.value = null }
    @Test fun backgroundDoesNotCreateAnInAppBanner() {
        AppPresence.setForeground(false)
        InAppMessageNotifications.show("chat", "background", "Sender", "Hello")
        assertNull(InAppMessageNotifications.current.value)
    }
    @Test fun readingTheSameChatSuppressesBanner() {
        AppPresence.setOpenConversation("chat")
        InAppMessageNotifications.show("chat", "open-chat", "Sender", "Hello")
        assertNull(InAppMessageNotifications.current.value)
    }
    @Test fun duplicateDeliveryDoesNotReshowDismissedMessage() {
        InAppMessageNotifications.show("chat", "duplicate", "Sender", "Hello")
        val first = InAppMessageNotifications.current.value!!
        InAppMessageNotifications.dismiss(first)
        InAppMessageNotifications.show("chat", "duplicate", "Sender", "Hello")
        assertNull(InAppMessageNotifications.current.value)
    }
    @Test fun staleDismissalPreservesNewBannerAndTapKeepsMessageTarget() {
        InAppMessageNotifications.show("first", "first-message", "A", "One")
        val old = InAppMessageNotifications.current.value!!
        InAppMessageNotifications.show("second", "second-message", "B", "Two")
        InAppMessageNotifications.dismiss(old)
        val current = InAppMessageNotifications.current.value!!
        DeepLinkRouter.open(current.conversationId, current.messageId)
        assertEquals("second", DeepLinkRouter.pendingConversation.value?.conversationId)
        assertEquals("second-message", DeepLinkRouter.pendingMessage.value?.messageId)
        DeepLinkRouter.consume(DeepLinkRouter.pendingConversation.value!!)
        assertNotNull(DeepLinkRouter.pendingMessage.value)
    }
    @Test fun backgroundingClearsVisiblePreview() {
        InAppMessageNotifications.show("chat", "clear-on-background", "Sender", "Hello")
        assertNotNull(InAppMessageNotifications.current.value)
        AppPresence.setForeground(false)
        assertNull(InAppMessageNotifications.current.value)
    }
    @Test fun sameChatBurstGroupsAndPreservesLatestMessage() {
        InAppMessageNotifications.show("burst", "burst-1", "A", "First")
        val stale = InAppMessageNotifications.current.value!!
        InAppMessageNotifications.show("burst", "burst-2", "A", "Second")
        InAppMessageNotifications.dismiss(stale)
        assertEquals(2, InAppMessageNotifications.current.value?.count)
        assertEquals("burst-2", InAppMessageNotifications.current.value?.messageId)
        assertEquals(1, InAppMessageNotifications.banners.value.size)
    }
    @Test fun dismissRevealsNextChatWithItsOwnMessage() {
        InAppMessageNotifications.show("queue-a", "queue-1", "A", "First")
        InAppMessageNotifications.show("queue-b", "queue-2", "B", "Second")
        InAppMessageNotifications.dismiss(InAppMessageNotifications.current.value!!)
        assertEquals("queue-a", InAppMessageNotifications.current.value?.conversationId)
        assertEquals("queue-1", InAppMessageNotifications.current.value?.messageId)
    }
    @Test fun queueIsBoundedToThreeChats() {
        repeat(5) { InAppMessageNotifications.show("bounded-$it", "bounded-msg-$it", "A", "Message") }
        assertEquals(3, InAppMessageNotifications.banners.value.size)
        assertEquals("bounded-4", InAppMessageNotifications.current.value?.conversationId)
    }
}

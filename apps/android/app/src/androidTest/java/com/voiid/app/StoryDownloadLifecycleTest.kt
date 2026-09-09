package com.voiid.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.voiid.app.model.Story
import com.voiid.app.model.StoryDownloadState
import com.voiid.app.model.StoryUploadState
import com.voiid.app.net.ChatEngine
import com.voiid.app.store.StoryLocalStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class StoryDownloadLifecycleTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture(expired: Boolean = false): Story {
        val now = System.currentTimeMillis()
        return Story(UUID.randomUUID().toString(), UUID.randomUUID().toString(), false, now - 2000,
            if (expired) now - 1000 else now + 60_000,
            ChatEngine.MediaRef("test", "image/jpeg", "key", "nonce", "hash"), "", null, null, null,
            true, null, null, StoryDownloadState.NONE, StoryUploadState.NONE)
    }

    @Test fun downloadedFileIsPublishedOnlyForALiveRowAndRemovedWithIt() = runBlocking {
        val story = fixture()
        try {
            StoryLocalStore.upsert(context, story)
            val path = requireNotNull(StoryLocalStore.commitDownload(context, story.id, byteArrayOf(1, 2, 3), StoryLocalStore.accountGeneration))
            assertArrayEquals(byteArrayOf(1, 2, 3), File(path).readBytes())
            assertEquals(StoryDownloadState.READY, StoryLocalStore.story(context, story.id)?.downloadState)
            StoryLocalStore.deleteStory(context, story.id)
            assertFalse(File(path).exists())
            assertNull(StoryLocalStore.commitDownload(context, story.id, byteArrayOf(4), StoryLocalStore.accountGeneration))
            assertFalse(File(path).exists())
        } finally { StoryLocalStore.deleteStory(context, story.id) }
    }

    @Test fun expiredOrPreviousAccountDownloadsCannotPublish() = runBlocking {
        for (expired in listOf(false, true)) {
            val story = fixture(expired)
            try {
                StoryLocalStore.upsert(context, story)
                val epoch = StoryLocalStore.accountGeneration - if (expired) 0 else 1
                assertNull(StoryLocalStore.commitDownload(context, story.id, byteArrayOf(1), epoch))
                assertFalse(File(StoryLocalStore.mediaDir(context), "${story.id}.bin").exists())
            } finally { StoryLocalStore.deleteStory(context, story.id) }
        }
    }
}

package com.voiid.app

import com.voiid.app.net.ChatEngine
import com.voiid.app.net.MessageBackupArchive
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class MessageBackupArchiveTest {
    private val user = "11111111-1111-1111-1111-111111111111"
    private val conv = "22222222-2222-2222-2222-222222222222"
    private val time = 1789460000125L
    private fun message(id: String = "m1", text: String = "local") = ChatEngine.DecryptedMessage(id,"peer",text,time,false,
        location = ChatEngine.LocationRef(kind="pin",lat=1.0,lon=2.0))
    private fun reject(block: () -> Unit) { try { block(); fail("invalid backup accepted") } catch (_: Exception) {} }

    @Test fun `iOS archive restores original timestamps and attachment keys`() {
        val bytes=javaClass.getResourceAsStream("/backup/ios-v1.json")!!.readBytes()
        val m=MessageBackupArchive.decode(bytes,user).getValue(conv).single()
        assertEquals(time,m.createdAt); assertEquals("image/jpeg",m.media!!.mime); assertEquals("k",m.media!!.key)
    }
    @Test fun `Android archive round trips and produces iOS fixture`() {
        val bytes=MessageBackupArchive.encode(user,mapOf(conv to listOf(message())))
        assertEquals(message(),MessageBackupArchive.decode(bytes,user).getValue(conv).single())
        val target=File("src/test/resources/backup/android-v1.json")
        target.parentFile.mkdirs(); target.writeBytes(bytes)
    }
    @Test fun `merge keeps local edits and tombstones without duplicating restored IDs`() {
        val tombstone=message().copy(deletedForMe=true,text="")
        val merged=MessageBackupArchive.merge(listOf(tombstone),listOf(message(),message("new"),message("new")))
        assertEquals(listOf(tombstone,message("new")),merged)
    }
    @Test fun `rejects corrupt archives other accounts future versions and unsafe paths`() {
        val data=MessageBackupArchive.encode(user,mapOf(conv to listOf(message())))
        reject { MessageBackupArchive.decode(data,"other") }
        reject { MessageBackupArchive.decode("not json".toByteArray(),user) }
        reject { MessageBackupArchive.decode("{\"../outside\":[]}".toByteArray(),user) }
        reject { MessageBackupArchive.decode(data.decodeToString().replace("\"version\":1","\"version\":999").toByteArray(),user) }
    }
    @Test fun `legacy iOS default fields and reference-date timestamps restore`() {
        val data="""{"$conv":[{"id":"m1","senderId":"peer","text":"old","createdAt":811152800.125,"isMine":false}]}""".toByteArray()
        assertEquals(time,MessageBackupArchive.decode(data,user).getValue(conv).single().createdAt)
    }
    @Test fun `legacy Android milliseconds remain milliseconds`() {
        val data="""{"$conv":[{"id":"m1","senderId":"peer","text":"old","createdAt":$time,"isMine":false}]}""".toByteArray()
        assertEquals(time,MessageBackupArchive.decode(data,user).getValue(conv).single().createdAt)
    }
}

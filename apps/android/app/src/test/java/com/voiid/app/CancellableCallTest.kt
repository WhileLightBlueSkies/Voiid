package com.voiid.app

import com.voiid.app.net.consumeCancellable
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CancellableCallTest {
    private fun cancellationDuring(bodyStarted: Boolean) = runBlocking {
        val accepted = CountDownLatch(1)
        val release = CountDownLatch(1)
        val server = ServerSocket(0)
        val worker = Thread {
            server.accept().use { socket ->
                if (bodyStarted) {
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\na".toByteArray())
                    socket.getOutputStream().flush()
                }
                accepted.countDown()
                release.await(5, TimeUnit.SECONDS)
            }
        }.apply { start() }
        val client = OkHttpClient.Builder().retryOnConnectionFailure(false).build()
        val call = client.newCall(Request.Builder().url("http://127.0.0.1:${server.localPort}").build())
        try {
            val job = launch(Dispatchers.IO) { call.consumeCancellable { it.body!!.string() } }
            assertTrue(accepted.await(3, TimeUnit.SECONDS))
            job.cancel()
            withTimeout(1000) { job.join() }
            assertTrue("Cancellation must reach the socket, including during body reads", call.isCanceled())
            assertTrue(job.isCancelled)
        } finally {
            release.countDown()
            server.close()
            worker.join(1000)
            client.dispatcher.executorService.shutdownNow()
            client.connectionPool.evictAll()
        }
    }

    @Test fun `cancel while awaiting response headers cancels call`() = cancellationDuring(false)
    @Test fun `cancel during body download cancels call`() = cancellationDuring(true)
}

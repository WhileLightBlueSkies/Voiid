package com.voiid.app.main

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Chat timestamp + date-separator helpers — port of iOS `DateFormatting.swift`. */
object VoiidDate {
    private val time = SimpleDateFormat("h:mm a", Locale.getDefault())
    private val full = SimpleDateFormat("d MMM yyyy", Locale.getDefault())
    private val weekday = SimpleDateFormat("EEEE", Locale.getDefault())

    /** Bubble timestamp, e.g. "9:41 AM". */
    fun bubbleTime(millis: Long): String = time.format(Date(millis))

    /** Date separator: Today / Yesterday / Monday / 12 Jun 2026. */
    fun separator(millis: Long): String {
        if (isToday(millis)) return "Today"
        if (isYesterday(millis)) return "Yesterday"
        val days = daysAgo(millis)
        if (days in 0 until 7) return weekday.format(Date(millis))
        return full.format(Date(millis))
    }

    /** Chat-list preview time: time if today, "Yesterday", else date. */
    fun listPreview(millis: Long?): String {
        if (millis == null) return ""
        if (isToday(millis)) return time.format(Date(millis))
        if (isYesterday(millis)) return "Yesterday"
        return full.format(Date(millis))
    }

    /** Calendar start-of-day for grouping messages by day. */
    fun startOfDay(millis: Long): Long = Calendar.getInstance().apply {
        timeInMillis = millis
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun isToday(millis: Long) = startOfDay(millis) == startOfDay(System.currentTimeMillis())
    private fun isYesterday(millis: Long) =
        startOfDay(millis) == startOfDay(System.currentTimeMillis()) - 86_400_000L
    private fun daysAgo(millis: Long): Long =
        (startOfDay(System.currentTimeMillis()) - startOfDay(millis)) / 86_400_000L
}

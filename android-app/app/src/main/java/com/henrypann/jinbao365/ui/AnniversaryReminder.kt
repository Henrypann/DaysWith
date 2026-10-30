package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.data.Anniversary
import java.time.LocalDate
import java.time.MonthDay
import java.time.temporal.ChronoUnit

internal data class AnniversaryReminder(val anniversary: Anniversary, val daysUntil: Int) {
    val text: String get() = if (daysUntil == 0) "今天是「${anniversary.title}」"
        else "还有 $daysUntil 天就是「${anniversary.title}」"
}

/** MonthDay deliberately maps February 29 to February 28 in a non-leap year. */
internal fun nextAnniversaryDate(date: LocalDate, today: LocalDate): LocalDate {
    val monthDay = MonthDay.from(date)
    val thisYear = monthDay.atYear(today.year)
    return if (thisYear < today) monthDay.atYear(today.year + 1) else thisYear
}

internal fun anniversaryReminder(anniversaries: List<Anniversary>, today: LocalDate): AnniversaryReminder? =
    anniversaries.asSequence().filter { it.deletedAt == null }.map {
        AnniversaryReminder(it, ChronoUnit.DAYS.between(today, nextAnniversaryDate(it.date, today)).toInt())
    }.filter { it.daysUntil in setOf(0, 1, 2, 3, 7) }
        .sortedWith(compareBy<AnniversaryReminder> { it.daysUntil }
            .thenBy { it.anniversary.title }.thenBy { it.anniversary.owner.folder }.thenBy { it.anniversary.id })
        .firstOrNull()

internal fun parseAnniversaryDate(value: String): LocalDate? =
    if (!Regex("\\d{4}-\\d{2}-\\d{2}").matches(value.trim())) null
    else runCatching { LocalDate.parse(value.trim()).takeIf { it.year in 1..9999 } }.getOrNull()

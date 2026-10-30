package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.DefaultAnniversaries
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.data.yearKnown
import java.time.LocalDate
import java.time.temporal.ChronoUnit

private val countdownWeekdays = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

internal data class CountdownEntry(val anniversary: Anniversary, val next: LocalDate, val daysUntil: Int) {
    val daysText: String get() = if (daysUntil == 0) "就是今天" else "还有 $daysUntil 天"
    val dateText: String get() = "${next.year}年${next.monthValue}月${next.dayOfMonth}日"

    /** Card line: month, day and weekday, plus the existing age or year when there is one. */
    val subtitleText: String get() {
        val weekday = countdownWeekdays[next.dayOfWeek.value - 1]
        val date = "${next.monthValue}月${next.dayOfMonth}日 $weekday"
        return milestoneText?.let { "$date · $it" } ?: date
    }

    /** 「X 岁」 for birthdays and 「第 N 年」 for other days, only when the original year is known. */
    val milestoneText: String? get() {
        if (!anniversary.yearKnown) return null
        val n = next.year - anniversary.date.year
        if (n <= 0) return null
        val birthday = anniversary.title.contains("生日")
        return if (birthday) "$n 岁" else "第 $n 年"
    }
}

internal fun countdownEntries(anniversaries: List<Anniversary>, today: LocalDate): List<CountdownEntry> =
    anniversaries.filter { it.deletedAt == null }.map {
        val next = nextAnniversaryDate(it.date, today)
        CountdownEntry(it, next, ChronoUnit.DAYS.between(today, next).toInt())
    }.sortedWith(compareBy<CountdownEntry> { it.daysUntil }.thenBy { it.anniversary.title }
        .thenBy { it.anniversary.owner.folder }.thenBy { it.anniversary.id })

/** A built-in day can acquire a local override even when the displayed value came from the other parent. */
internal fun canManageAnniversary(anniversary: Anniversary, parent: ParentIdentity?): Boolean =
    parent != null && (anniversary.owner == parent || DefaultAnniversaries.isDefault(anniversary.id))

/** Accepts 「YYYY-MM-DD」 or year-less 「MM-DD」 (stored with the unknown-year sentinel). */
internal fun parseCountdownDate(value: String): LocalDate? {
    val text = value.trim()
    if (Regex("\\d{1,2}-\\d{1,2}").matches(text)) {
        val (m, d) = text.split("-").map { it.toInt() }
        return runCatching { LocalDate.of(DefaultAnniversaries.UNKNOWN_YEAR, m, d) }.getOrNull()
    }
    return parseAnniversaryDate(text)?.takeIf { it.year != DefaultAnniversaries.UNKNOWN_YEAR }
}

internal fun countdownDateInput(date: LocalDate): String =
    if (date.year == DefaultAnniversaries.UNKNOWN_YEAR) "%02d-%02d".format(date.monthValue, date.dayOfMonth)
    else date.toString()

package com.henrypann.jinbao365.ui

import java.time.LocalDate
import java.time.temporal.ChronoUnit


data class JinbaoAge(val years: Int, val months: Int, val days: Int) {
    val fullLabel: String get() = "${years}岁${months}个月${days}天"
    val monthLabel: String get() = "${years}岁${months}个月"
}

/** Age requires a user-supplied date; there is no private default birthday. */
fun jinbaoAge(date: LocalDate, birthday: LocalDate? = null): JinbaoAge? {
    if (birthday == null || date < birthday) return null
    val months = ChronoUnit.MONTHS.between(birthday, date)
    val days = ChronoUnit.DAYS.between(birthday.plusMonths(months), date)
    return JinbaoAge((months / 12).toInt(), (months % 12).toInt(), days.toInt())
}

fun jinbaoDateHeader(date: LocalDate): String = "${date.monthValue}月${date.dayOfMonth}日"

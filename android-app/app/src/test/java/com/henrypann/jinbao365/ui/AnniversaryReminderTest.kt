package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class AnniversaryReminderTest {
    private fun event(date: String, title: String = "示例生日", id: String = "birthday") =
        Anniversary(id, ParentIdentity.Dad, title, LocalDate.parse(date))

    @Test fun onlySevenThreeTwoOneAndTheDayAppearWithExactChineseCopy() {
        val anniversary = event("1992-05-16")
        val occurrence = LocalDate.of(2026, 5, 16)
        for (days in 0..8) {
            val reminder = anniversaryReminder(listOf(anniversary), occurrence.minusDays(days.toLong()))
            if (days in listOf(0, 1, 2, 3, 7)) {
                assertEquals(days, reminder?.daysUntil)
                assertEquals(if (days == 0) "今天是「示例生日」" else "还有 $days 天就是「示例生日」", reminder?.text)
            } else assertNull(reminder)
        }
        assertNull(anniversaryReminder(listOf(anniversary), occurrence.plusDays(1)))
    }

    @Test fun januaryAnniversaryCountsAcrossDecemberAndKeepsShowingThroughoutTargetDate() {
        val anniversary = event("2020-01-01", "新的一年")
        assertEquals(7, anniversaryReminder(listOf(anniversary), LocalDate.of(2026, 12, 25))?.daysUntil)
        assertNull(anniversaryReminder(listOf(anniversary), LocalDate.of(2026, 12, 28)))
        assertEquals(3, anniversaryReminder(listOf(anniversary), LocalDate.of(2026, 12, 29))?.daysUntil)
        assertEquals(1, anniversaryReminder(listOf(anniversary), LocalDate.of(2026, 12, 31))?.daysUntil)
        val today = LocalDate.of(2027, 1, 1)
        repeat(3) { assertEquals("今天是「新的一年」", anniversaryReminder(listOf(anniversary), today)?.text) }
    }

    @Test fun leapDayUsesFebruary28InOrdinaryAndCenturyNonLeapYears() {
        val anniversary = event("2024-02-29", "特别的生日")
        for (year in listOf(2025, 2026, 2100)) {
            assertEquals(7, anniversaryReminder(listOf(anniversary), LocalDate.of(year, 2, 21))?.daysUntil)
            assertEquals(1, anniversaryReminder(listOf(anniversary), LocalDate.of(year, 2, 27))?.daysUntil)
            assertEquals(0, anniversaryReminder(listOf(anniversary), LocalDate.of(year, 2, 28))?.daysUntil)
            assertNull(anniversaryReminder(listOf(anniversary), LocalDate.of(year, 3, 1)))
        }
    }

    @Test fun leapYearUsesFebruary29AndNextOccurrenceReturnsToLeapDay() {
        val anniversary = event("2024-02-29")
        assertEquals(7, anniversaryReminder(listOf(anniversary), LocalDate.of(2028, 2, 22))?.daysUntil)
        assertEquals(1, anniversaryReminder(listOf(anniversary), LocalDate.of(2028, 2, 28))?.daysUntil)
        assertEquals(0, anniversaryReminder(listOf(anniversary), LocalDate.of(2028, 2, 29))?.daysUntil)
        assertEquals(LocalDate.of(2028, 2, 29), nextAnniversaryDate(anniversary.date, LocalDate.of(2027, 3, 1)))
    }

    @Test fun closestMatchingDateWinsThenTitleRegardlessOfInputOrder() {
        val today = LocalDate.of(2026, 5, 13)
        val entries = listOf(event("2020-05-20", "七天", "seven"), event("2020-05-16", "三天", "three"),
            event("2020-05-13", "乙", "b"), event("2020-05-13", "一", "a"))
        val expected = entries.filter { it.date.dayOfMonth == 13 }.minBy { it.title }.id
        assertEquals(expected, anniversaryReminder(entries, today)?.anniversary?.id)
        assertEquals(expected, anniversaryReminder(entries.reversed(), today)?.anniversary?.id)
    }

    @Test fun deletedAndEmptyListsNeverProduceReminders() {
        val today = LocalDate.of(2026, 5, 16)
        assertNull(anniversaryReminder(emptyList(), today))
        assertNull(anniversaryReminder(listOf(event("2020-05-16").copy(deletedAt = 1)), today))
    }

    @Test fun dateInputRejectsInvalidCalendarDatesAndAcceptsLeapDay() {
        for (invalid in listOf("", "2026-02-29", "2026-04-31", "2026-13-01", "10-16", "0000-01-01")) {
            assertNull(invalid, parseAnniversaryDate(invalid))
        }
        assertEquals(LocalDate.of(2024, 2, 29), parseAnniversaryDate("2024-02-29"))
    }
}

package com.henrypann.jinbao365.ui

import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test

class JinbaoAgeTest {
    @Test fun noPrivateBirthdayIsAssumed() {
        val date = LocalDate.of(2030, 2, 3)
        assertNull(jinbaoAge(date))
        assertEquals("2月3日", jinbaoDateHeader(date))
    }
    @Test fun explicitBirthdayUsesNaturalMonths() {
        val birthday = LocalDate.of(2020, 2, 3)
        assertEquals(JinbaoAge(1, 0, 25), jinbaoAge(LocalDate.of(2021, 2, 28), birthday))
        assertEquals(JinbaoAge(1, 1, 0), jinbaoAge(LocalDate.of(2021, 3, 3), birthday))
        assertNull(jinbaoAge(birthday.minusDays(1), birthday))
    }
}

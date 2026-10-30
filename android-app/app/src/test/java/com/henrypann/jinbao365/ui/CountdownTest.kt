package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.DefaultAnniversaries
import com.henrypann.jinbao365.data.ParentIdentity
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class CountdownTest {
    private val owner = ParentIdentity.Dad
    private fun defaults() = DefaultAnniversaries.merge(emptyList(), owner)

    @Test fun onlyPublicAnnualDaysHaveNoInventedYear() {
        assertEquals(listOf("儿童节", "国庆节", "元旦"), defaults().map { it.title })
        assertTrue(defaults().all { it.date.year == DefaultAnniversaries.UNKNOWN_YEAR })
        val entries = countdownEntries(defaults(), LocalDate.of(2030, 12, 31))
        assertEquals("元旦", entries.first().anniversary.title)
        assertEquals(1, entries.first().daysUntil)
        assertTrue(entries.all { it.milestoneText == null })
        assertEquals(0, countdownEntries(defaults(), LocalDate.of(2030, 6, 1)).first().daysUntil)
    }
    @Test fun repeatedInitializationAndUpgradePreserveOverridesAndLegacyRows() {
        val edited = Anniversary(DefaultAnniversaries.CHILDRENS_DAY_ID, owner, "自定义", LocalDate.of(2021, 2, 14))
        val deleted = Anniversary(DefaultAnniversaries.NATIONAL_DAY_ID, owner, "已删除", LocalDate.of(4, 10, 1), deletedAt = 9)
        val legacy = Anniversary("00000000-0000-4000-8000-000000000001", owner, "用户已保存", LocalDate.of(2000, 2, 3))
        val stored = listOf(edited, deleted, legacy)
        val first = DefaultAnniversaries.merge(stored, owner)
        assertEquals(first, DefaultAnniversaries.merge(first, owner))
        assertEquals(4, first.size)
        assertEquals(edited, first.single { it.id == edited.id })
        assertEquals(deleted, first.single { it.id == deleted.id })
        assertEquals(legacy, first.single { it.id == legacy.id })
        assertEquals(stored, listOf(edited, deleted, legacy))
    }
    @Test fun localOverrideWinsAndRemoteTombstoneHidesDefault() {
        val remote = Anniversary(DefaultAnniversaries.CHILDRENS_DAY_ID, ParentIdentity.Mom, "另一设备", LocalDate.of(4, 2, 14))
        val local = remote.copy(owner = owner, title = "本机")
        assertEquals(local, DefaultAnniversaries.merge(listOf(remote, local), owner).single { it.id == local.id })
        val deleted = remote.copy(deletedAt = 10)
        assertEquals(deleted, DefaultAnniversaries.merge(listOf(deleted), owner).single { it.id == deleted.id })
    }
    @Test fun leapDayAndYearlessInputRetainCalendarSemantics() {
        val event = Anniversary("x", owner, "示例", LocalDate.of(4, 2, 29))
        assertEquals(LocalDate.of(2031, 2, 28), countdownEntries(listOf(event), LocalDate.of(2030, 3, 1)).single().next)
        assertEquals(LocalDate.of(4, 2, 29), parseCountdownDate("02-29"))
        assertNull(parseCountdownDate("2030-02-29"))
    }
}

package com.henrypann.jinbao365.data

import java.time.LocalDate

/**
 * Built-in yearly days. They are never seeded as rows: they are shown virtually until a parent edits
 * or deletes one, which stores a normal row (or tombstone) under the same fixed ID. Nothing is inserted
 * on install, upgrade or restore, so defaults can never be duplicated.
 */
object DefaultAnniversaries {
    /** Sentinel year for "year not filled in". Year 4 is a leap year, so 2/29 stays representable. */
    const val UNKNOWN_YEAR = 4


    data class Default(val id: String, val title: String, val date: LocalDate)

    const val CHILDRENS_DAY_ID = "00000000-0000-4000-8000-000000000101"
    const val NATIONAL_DAY_ID = "00000000-0000-4000-8000-000000000102"
    const val NEW_YEAR_ID = "00000000-0000-4000-8000-000000000103"
    val all: List<Default> = listOf(
        Default(CHILDRENS_DAY_ID, "儿童节", LocalDate.of(UNKNOWN_YEAR, 6, 1)),
        Default(NATIONAL_DAY_ID, "国庆节", LocalDate.of(UNKNOWN_YEAR, 10, 1)),
        Default(NEW_YEAR_ID, "元旦", LocalDate.of(UNKNOWN_YEAR, 1, 1)),
    )

    private val ids = all.map { it.id.lowercase() }.toSet()

    fun isDefault(id: String): Boolean = id.lowercase() in ids

    /**
     * Visible list = stored rows plus any default no parent has touched. For a default ID the local
     * parent's row wins, else the other parent's; a tombstone hides it. Returns rows incl. tombstones
     * so callers keep their existing deletedAt filtering.
     */
    fun merge(stored: List<Anniversary>, localOwner: ParentIdentity?): List<Anniversary> {
        val (defaultRows, others) = stored.partition { isDefault(it.id) }
        val resolved = all.mapNotNull { d ->
            val rows = defaultRows.filter { it.id.equals(d.id, ignoreCase = true) }
            when {
                rows.isEmpty() -> localOwner?.let { Anniversary(d.id, it, d.title, d.date) }
                else -> rows.firstOrNull { it.owner == localOwner } ?: rows.first()
            }
        }
        return others + resolved
    }
}

val Anniversary.yearKnown: Boolean get() = date.year != DefaultAnniversaries.UNKNOWN_YEAR

package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.importProvenance
import com.henrypann.jinbao365.archive.hasRecordText
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.viewing.partnerIdentityOf
import com.henrypann.jinbao365.editing.MomentDraft
import com.henrypann.jinbao365.editing.momentDraft
import kotlinx.serialization.json.*
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.media.CaptureTime
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal data class MomentDetail(
    val id: String,
    val title: String,
    val note: String,
    val dateTimeLabel: String,
    val trashed: Boolean,
    val media: List<MomentMedia>,
)

internal data class MomentMedia(
    val assetId: String,
    val kind: String,
    val image: MediaResource?,
    val thumbnail: MediaResource? = null,
    val original: MediaResource? = null,
    val partner: ParentIdentity? = null,
    val provenance: ImportProvenance = ImportProvenance.Unknown,
    val captureTimeLabel: String = "拍摄时间未知",
)

/** The same Unicode whitespace policy as Stage A's commit validation. */
internal fun canSaveMoment(draft: MomentDraft): Boolean =
    draft.assetIds.isNotEmpty() || hasRecordText(draft.title, draft.note)

/** Reordering changes only protocol assetIDs order; an edge or stale selection is a no-op. */
internal fun moveMomentMedia(draft: MomentDraft, assetId: String, offset: Int): MomentDraft {
    val from = draft.assetIds.indexOf(assetId)
    val to = from + offset
    if (from < 0 || to !in draft.assetIds.indices || offset == 0) return draft
    val ordered = draft.assetIds.toMutableList()
    ordered.add(to, ordered.removeAt(from))
    return draft.copy(assetIds = ordered)
}

internal fun momentFieldText(value: JsonElement?): String =
    (value as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()

internal fun momentDateTimeLabel(millis: Long, zoneId: ZoneId = ZoneId.systemDefault()): String =
    DateTimeFormatter.ofPattern("M月d日 HH:mm", Locale.CHINA)
        .format(Instant.ofEpochMilli(millis).atZone(zoneId))

internal const val UNKNOWN_RECORD_TIME_LABEL = "日期与时间未知"

internal fun recordDateTimeLabel(millis: Long, zoneId: ZoneId = ZoneId.systemDefault()): String =
    if (isKnownRecordTime(millis)) momentDateTimeLabel(millis, zoneId) else UNKNOWN_RECORD_TIME_LABEL

internal fun momentDetailModel(snapshot: ArchiveSnapshot, recordId: String): MomentDetail? {
    val record = snapshot.records.firstOrNull { it.id == recordId } ?: return null
    val values = momentDraft(record)
    val assets = snapshot.assets.associateBy { it.id }
    val resources = snapshot.resources.associateBy { it.id }
    return MomentDetail(
        id = record.id,
        title = values.title.ifBlank { "值得留住的小日常" },
        note = values.note,
        dateTimeLabel = recordDateTimeLabel(values.occurredAtMillis),
        trashed = !record.tombstone.isNullValue(),
        media = values.assetIds.map { id ->
            val asset = assets[id]
            val owned = asset?.resourceIds.orEmpty().mapNotNull(resources::get).filter { it.assetID == id }
            val thumbnail = owned.firstOrNull { it.role == "preview" }
            val original = owned.firstOrNull { it.role in setOf("photo", "motionPhoto", "livePhotoImage", "video") }
                ?: owned.firstOrNull { it.role != "preview" }
            MomentMedia(id, asset?.kind ?: "unknown",
                owned.firstOrNull { it.role in setOf("photo", "motionPhoto", "livePhotoImage") } ?: thumbnail,
                thumbnail, original, partnerIdentityOf(record.id), asset?.importProvenance ?: ImportProvenance.Unknown, captureTimeLabel(asset))
        },
    )
}

/** Use the shooting offset when known; never label record/import time as capture time. */
internal fun captureTimeLabel(asset: MediaAsset?): String {
    val raw = asset?.capturedAt?.value as? JsonObject ?: return "拍摄时间未知"
    val capture = CaptureTime.atRead(raw)
    val utc = (capture["utc"] as? JsonPrimitive)?.longOrNull ?: return "拍摄时间未知"
    val zoneName = (capture["timeZone"] as? JsonPrimitive)?.contentOrNull
    val offset = (capture["utcOffset"] as? JsonPrimitive)?.contentOrNull
    val zone = runCatching { ZoneId.of(zoneName ?: offset ?: "UTC") }.getOrDefault(ZoneId.of("UTC"))
    val format = DateTimeFormatter.ofPattern("yyyy年M月d日 HH:mm:ss.SSS", Locale.CHINA)
    val suffix = zoneName ?: offset?.let { if (it == "Z") "UTC" else "UTC$it" } ?: "UTC · 拍摄时区未知"
    return "拍摄时间：${format.format(Instant.ofEpochMilli(utc).atZone(zone))} $suffix"
}

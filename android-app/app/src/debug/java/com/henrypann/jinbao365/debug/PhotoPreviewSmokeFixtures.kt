package com.henrypann.jinbao365.debug

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.editing.newDraftRecord
import com.henrypann.jinbao365.media.CaptureTime
import kotlinx.serialization.json.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.ZoneId
import java.util.UUID

/** Synthetic bytes only. Never opens the production archive or rewrites an existing fixture. */
internal class PhotoPreviewSmokeFixtures(private val context: Context) {
    val root = File(context.filesDir, "pr8-smoke-media")
    val sources = File(context.filesDir, "pr8-smoke-source")
    private val manifestFile = File(context.filesDir, "pr8-smoke-fixtures.json")
    val manifest: JSONObject
    val snapshot: ArchiveSnapshot
    val scenes: Map<String, String>
    init {
        if (!manifestFile.exists()) generate()
        manifest = JSONObject(manifestFile.readText())
        snapshot = withLocalVideo(readProjection())
        val sceneJson = manifest.getJSONObject("scenes")
        scenes = sceneJson.keys().asSequence().associateWith { sceneJson.getString(it) }
    }
    private fun readProjection(): ArchiveSnapshot {
        // The persisted fixture contains view-layer remote cache paths, while v3 validates canonical
        // object keys. Validate the archived shape first, then restore only generated local paths.
        val json = Json.parseToJsonElement(File(context.filesDir, "pr8-smoke-snapshot.json").readText()).jsonObject
        val paths = json.getValue("resources").jsonArray.associate {
            it.jsonObject.getValue("id").jsonPrimitive.content to it.jsonObject.getValue("objectKey").jsonPrimitive.content
        }
        val normalized = JsonObject(json + ("resources" to JsonArray(json.getValue("resources").jsonArray.map {
            val resource = it.jsonObject
            val hash = resource.getValue("sha256").jsonPrimitive.content
            JsonObject(resource + ("objectKey" to JsonPrimitive("objects/${hash.take(2)}/$hash")))
        })))
        val parsed = ArchiveJson.parseSnapshot(normalized)
        return parsed.copy(resources = parsed.resources.map { it.copy(objectKey = paths.getValue(it.id)) })
    }
    private fun withLocalVideo(value: ArchiveSnapshot): ArchiveSnapshot {
        val source = File(context.filesDir, "pr8-smoke-video.mp4")
        if (!source.isFile) return value
        val hash = SeedScenes.sha256(source)
        val path = "objects/${hash.take(2)}/$hash"
        val target = File(root, path)
        if (!target.exists()) { target.parentFile!!.mkdirs(); source.copyTo(target) }
        return value.copy(resources = value.resources.map {
            if (it.role == "video") it.copy(byteCount = source.length(), sha256 = hash, objectKey = path) else it
        })
    }
    val localSnapshot get(): ArchiveSnapshot {
        val records = snapshot.records.filter { it.id == scenes["local"] }
        val ids = records.flatMap { jsonStringList(it.assetIds.value) }.toSet()
        return snapshot.copy(records = records, assets = snapshot.assets.filter { it.id in ids },
            resources = snapshot.resources.filter { it.assetID in ids })
    }
    private fun generate() {
        check(!root.exists() || root.listFiles().orEmpty().isEmpty())
        check(!sources.exists() || sources.listFiles().orEmpty().isEmpty())
        root.mkdirs(); sources.mkdirs()
        val at = System.currentTimeMillis()
        val zone = ZoneId.of("Asia/Shanghai")
        val writer = UUID.randomUUID().toString()
        fun field(value: JsonElement) = FieldEnvelope(value, EditStamp(1, at, writer))
        val records = mutableListOf<ArchiveRecord>()
        val assets = mutableListOf<MediaAsset>()
        val resources = mutableListOf<MediaResource>()
        val scenes = JSONObject()
        val uploads = JSONArray()
        val colors = listOf("#E4A94C", "#4CA4C9", "#B788C5", "#63B59D", "#E07D77", "#6B8ED4", "#B2AD55", "#63868D")
        var ordinal = 0
        for (scene in listOf("local", "remote-a", "remote-b", "remote-c", "remote-d", "video")) {
            val remote = scene.startsWith("remote-")
            val video = scene == "video"
            val recordId = (if (remote) "remote:mom:" else "") + UUID.randomUUID()
            scenes.put(scene, recordId)
            val recordAssets = mutableListOf<String>()
            repeat(if (scene == "local") 3 else 1) { index ->
                val assetId = UUID.randomUUID().toString()
                val originalId = UUID.randomUUID().toString()
                val thumbId = UUID.randomUUID().toString()
                val label = if (scene != "local") scene.uppercase() else "LOCAL ${index + 1}"
                val source = File(sources, "$scene-$index.jpg")
                draw(source, label, colors[ordinal++], thumbnail = false)
                val hash = SeedScenes.sha256(source)
                val logical = "life/v1/mom/objects/${hash.take(2)}/$hash"
                val path = if (remote) "remote/mom/objects/${hash.take(2)}/$hash" else "objects/${hash.take(2)}/$hash"
                if (!remote && !video) File(root, path).apply { parentFile!!.mkdirs(); source.copyTo(this) }
                val thumb = File(root, "remote/mom/thumbs/$thumbId.jpg").apply { parentFile!!.mkdirs() }
                draw(thumb, label, "#84909E", thumbnail = true)
                val original = MediaResource(originalId, assetId, if (video) "video" else "photo",
                    if (video) "video/mp4" else "image/jpeg", if (video) "synthetic-video.mp4" else "$scene-$index.jpg",
                    if (video) 12_582_912 else source.length(), if (video) "f1".repeat(32) else hash, path, emptyMap())
                val preview = MediaResource(thumbId, assetId, "preview", "image/jpeg", "$scene-thumb.jpg",
                    thumb.length(), SeedScenes.sha256(thumb), root.toPath().relativize(thumb.toPath()).toString(), emptyMap())
                resources += original
                resources += preview
                assets += MediaAsset(assetId, if (video) "video" else "photo", field(CaptureTime.iana(at, zone.id)),
                    listOf(originalId, thumbId), emptyMap())
                recordAssets += assetId
                if (remote && !video) uploads.put(JSONObject().put("scene", scene)
                    .put("source", "pr8-smoke-source/${source.name}").put("logicalKey", logical)
                    .put("testRelativeKey", "mom/objects/${hash.take(2)}/$hash")
                    .put("sha256", hash).put("byteCount", source.length()).put("contentType", "image/jpeg"))
            }
            records += newDraftRecord(recordId, writer, at, zone).copy(
                title = field(JsonPrimitive(if (scene == "local") "本机照片 · 三张原图" else if (video) "视频封面" else "妈妈的照片 · ${scene.takeLast(1).uppercase()}")),
                note = field(JsonPrimitive("Synthetic PR 8 device acceptance fixture")),
                assetIds = field(JsonArray(recordAssets.map(::JsonPrimitive))))
        }
        val snapshot = ArchiveSnapshot.empty().copy(records = records, assets = assets, resources = resources)
        File(context.filesDir, "pr8-smoke-snapshot.json").writeText(ArchiveJson.canonical(snapshot))
        manifestFile.writeText(JSONObject().put("version", 1).put("writer", writer).put("createdAt", at)
            .put("scenes", scenes).put("uploads", uploads).toString(2))
    }
    private fun draw(file: File, label: String, color: String, thumbnail: Boolean) {
        val width = if (thumbnail) 240 else 2400
        val height = if (thumbnail) 320 else 3200
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.parseColor(color))
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = Color.WHITE }
            val unit = width / 12f
            for (row in 0..15) for (column in 0..11) {
                paint.alpha = if ((row + column) % 2 == 0) 38 else 90
                canvas.drawRect(column * unit, row * unit, (column + 1) * unit, (row + 1) * unit, paint)
            }
            paint.alpha = 255; paint.textSize = width / 12f
            canvas.drawText(label, width * .07f, height * .32f, paint)
            paint.textSize = width / 16f
            canvas.drawText(if (thumbnail) "THUMBNAIL" else "ORIGINAL 2400 x 3200", width * .07f, height * .42f, paint)
            if (!thumbnail) {
                paint.textSize = 24f
                for (row in 0..24) canvas.drawText("Detail ${row + 1}: ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789", 160f, 1700f + row * 35, paint)
            }
            file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)) }
        } finally { bitmap.recycle() }
    }
}

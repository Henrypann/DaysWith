package com.henrypann.jinbao365.debug

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.editing.newDraftRecord
import com.henrypann.jinbao365.media.CaptureTime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/** Everything, including the database, stays apart from the real family archive. */
internal object SeedScenes {
    const val DATABASE_NAME = "debug-seed.db"
    private const val DEVICE = "debug-local-scene"
    private val zone = ZoneId.of("Asia/Shanghai")

    fun mediaRoot(context: Context) = File(context.filesDir, "debug-seed/media")

    fun parentOf(snapshot: ArchiveSnapshot, recordId: String): ParentIdentity? {
        val value = (snapshot.records.firstOrNull { it.id == recordId }?.extensions?.get("parent")?.value
            as? JsonPrimitive)?.content
        return ParentIdentity.entries.firstOrNull { it.folder == value }
    }

    /** Repeating the scene replaces only its own sample database, always off the main thread. */
    suspend fun seed(context: Context, nowMillis: Long = System.currentTimeMillis()): ArchiveSnapshot = withContext(Dispatchers.IO) {
        val root = mediaRoot(context).also { it.mkdirs() }
        val day = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
        val scenes = listOf(
            Sample(ParentIdentity.Mom, "公园里的小发现", "蹲下来认真看一片落叶，一看就是好久。", 0, 16, true),
            Sample(ParentIdentity.Dad, "今天会说谢谢啦", "递给孩子一杯水，听见一声小小的“谢谢爸爸”。这句话要记很久。", 0, 14, false),
            Sample(ParentIdentity.Dad, "一起追着阳光跑", "午后的草地暖暖的，笑声比风跑得还快。", 1, 15, true),
            Sample(ParentIdentity.Mom, "睡前的小约定", "今晚读了三遍最喜欢的故事。说好明天还要一起看月亮。", 1, 10, false),
            Sample(ParentIdentity.Mom, "抱紧心爱的小熊", "出门也要带着它，说这是自己的好朋友。", 2, 11, true),
            Sample(ParentIdentity.Dad, "普通的一天也很珍贵", "一起吃早饭、搭积木、散步。原来最想留下的，就是这些小日常。", 3, 9, false),
        )
        val assets = mutableListOf<MediaAsset>()
        val resources = mutableListOf<MediaResource>()
        val records = scenes.mapIndexed { index, scene ->
            val at = day.minusDays(scene.daysAgo).atTime(scene.hour, 30).atZone(zone).toInstant().toEpochMilli()
            fun field(value: JsonElement) = FieldEnvelope(value, EditStamp(1, at, DEVICE))
            val assetIds = if (scene.photo) {
                val assetId = id("asset-$index")
                val resourceId = id("resource-$index")
                val file = File(root, "seed-$index.jpg")
                drawPhoto(file, index)
                val hash = sha256(file)
                val objectKey = "objects/${hash.take(2)}/$hash"
                val original = File(root, objectKey)
                original.parentFile!!.mkdirs()
                file.copyTo(original, overwrite = true)
                file.delete()
                resources += MediaResource(
                    id = resourceId, assetID = assetId, role = "photo", contentType = "image/jpeg",
                    originalFilename = "孩子的小日常${index + 1}.jpg", byteCount = original.length(), sha256 = hash,
                    objectKey = objectKey, extensions = emptyMap(),
                )
                assets += MediaAsset(assetId, "photo", field(CaptureTime.iana(at, zone.id)), listOf(resourceId), emptyMap())
                listOf(assetId)
            } else emptyList()
            newDraftRecord(id("record-$index"), DEVICE, at, zone).copy(
                title = field(JsonPrimitive(scene.title)), note = field(JsonPrimitive(scene.note)),
                assetIds = field(JsonArray(assetIds.map(::JsonPrimitive))),
                extensions = mapOf("parent" to field(JsonPrimitive(scene.parent.folder))),
            )
        }
        val database = ArchiveDatabase.open(context, DATABASE_NAME)
        try {
            val repository = ArchiveRepository(database)
            repository.saveSnapshot(ArchiveSnapshot.empty().copy(records = records, assets = assets, resources = resources))
            repository.loadSnapshot()
        } finally {
            database.close()
        }
    }

    internal fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val bytes = ByteArray(16 * 1024)
            while (true) {
                val count = input.read(bytes)
                if (count < 0) break
                digest.update(bytes, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun id(value: String) = UUID.nameUUIDFromBytes("jinbao-debug-$value".toByteArray()).toString()

    /** Canvas-generated sample photographs need no storage permission or network. */
    private fun drawPhoto(file: File, variant: Int) {
        val width = if (variant == 2) 960 else 720
        val height = if (variant == 2) 720 else 960
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            fun circle(x: Float, y: Float, radius: Float, color: String) {
                paint.color = Color.parseColor(color)
                canvas.drawCircle(x * width, y * height, radius * width, paint)
            }
            fun oval(left: Float, top: Float, right: Float, bottom: Float, color: String) {
                paint.color = Color.parseColor(color)
                canvas.drawOval(left * width, top * height, right * width, bottom * height, paint)
            }
            canvas.drawColor(Color.parseColor(if (variant == 4) "#F1DFCB" else "#B7DADE"))
            circle(.78f, .17f, .11f, "#FFF1C2")
            oval(-.25f, .50f, 1.25f, 1.35f, "#A8BB83")
            oval(-.4f, .73f, 1.3f, 1.5f, "#D3C391")
            if (variant != 4) {
                circle(.08f, .29f, .27f, "#7F9D6D")
                circle(.18f, .13f, .22f, "#93AB76")
            }
            // A warm, simple child-and-bear illustration in each locally generated bitmap.
            oval(.29f, .53f, .70f, .96f, if (variant == 2) "#D99165" else "#E4B967")
            circle(.50f, .40f, .17f, "#F2CFA5")
            oval(.33f, .22f, .66f, .38f, "#675046")
            circle(.44f, .40f, .010f, "#675046")
            circle(.56f, .40f, .010f, "#675046")
            oval(.465f, .455f, .535f, .475f, "#CC8B79")
            circle(.68f, .66f, .08f, "#BD9169")
            circle(.77f, .66f, .08f, "#BD9169")
            oval(.63f, .67f, .81f, .87f, "#BD9169")
            circle(.72f, .71f, .04f, "#EAD6B7")
            circle(.705f, .70f, .007f, "#675046")
            circle(.745f, .70f, .007f, "#675046")
            file.outputStream().use { output -> check(bitmap.compress(Bitmap.CompressFormat.JPEG, 92, output)) }
        } finally {
            bitmap.recycle()
        }
    }

    private data class Sample(
        val parent: ParentIdentity, val title: String, val note: String,
        val daysAgo: Long, val hour: Int, val photo: Boolean,
    )
}

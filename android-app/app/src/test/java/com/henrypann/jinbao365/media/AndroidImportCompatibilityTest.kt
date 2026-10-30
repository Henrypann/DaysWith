package com.henrypann.jinbao365.media

import android.content.ContentProvider
import android.content.ContentValues
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ProviderInfo
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBuild
import org.robolectric.shadows.ShadowContentResolver
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 35])
class AndroidImportCompatibilityTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    @Config(sdk = [31])
    fun android12WithoutABackportUsesTheOpenDocumentPath() {
        val context = context()
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, PickVisualMedia().createIntent(
            context, PickVisualMediaRequest(PickVisualMedia.ImageAndVideo),
        ).action)
        assertTrue(usesDocumentPicker(context))
        assertTrue(usesDocumentPicker(context, maxItems = 30))
        val intent = ActivityResultContracts.OpenDocument().createIntent(context, arrayOf("image/*", "video/*"))
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
        assertArrayEquals(arrayOf("image/*", "video/*"), intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
    }

    @Test
    @Config(sdk = [35])
    fun aCurrentAndroidUsesTheNativePicker() {
        assertFalse(usesDocumentPicker(context()))
        assertFalse(usesDocumentPicker(context(), maxItems = 30))
        assertEquals(MediaStore.ACTION_PICK_IMAGES, PickVisualMedia().createIntent(
            context(), PickVisualMediaRequest(PickVisualMedia.ImageAndVideo),
        ).action)
    }

    @Test
    fun oppoManufacturerOrBrandKeepsNativePickerIgnoringCase() {
        listOf("OPPO", "oppo", "OpPo").forEach { identity ->
            assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES, null,
                manufacturer = identity, brand = "other"))
            assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES, null,
                manufacturer = "other", brand = identity))
        }
    }

    @Test
    fun otherAndSimilarDeviceNamesKeepTheNativePicker() {
        listOf("OnePlus", "realme", "Oplus", "OPPO Mobile", " OPPO", "OPPO ", "").forEach { identity ->
            assertFalse(identity, shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES, null,
                manufacturer = identity, brand = identity))
        }
    }

    @Test
    @Config(sdk = [35])
    fun oppoNativeSingleAndMultiplePickersStayNative() {
        val context = context()
        assertEquals(MediaStore.ACTION_PICK_IMAGES, PickVisualMedia().createIntent(
            context, PickVisualMediaRequest(PickVisualMedia.ImageAndVideo),
        ).action)
        listOf("OPPO" to "other", "oppo" to "other", "OpPo" to "other",
            "other" to "OPPO", "other" to "oppo", "other" to "OpPo").forEach { (manufacturer, brand) ->
            ShadowBuild.setManufacturer(manufacturer)
            ShadowBuild.setBrand(brand)
            assertFalse("$manufacturer / $brand single", usesDocumentPicker(context))
            assertFalse("$manufacturer / $brand multiple", usesDocumentPicker(context, maxItems = 30))
        }
        val document = ActivityResultContracts.OpenMultipleDocuments().createIntent(context, arrayOf("image/*", "video/*"))
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, document.action)
        assertTrue(document.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertArrayEquals(arrayOf("image/*", "video/*"), document.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
    }

    @Test
    fun originalPickerRoutingKeepsOpenDocumentAndMatchesOnlyTheVerifiedHyperComponent() {
        val hyper = ComponentName("com.android.photopicker", "com.android.photopicker.hyper.HyperMainActivity")
        assertTrue(shouldUseDocumentPicker(Intent.ACTION_OPEN_DOCUMENT, null))
        assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES, hyper))
        assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES,
            ComponentName("com.android.providers.media", "com.android.providers.media.photopicker.PhotoPickerActivity")))
        assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES,
            ComponentName("other.picker", hyper.className)))
        assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES,
            ComponentName(hyper.packageName, "com.android.photopicker.MainActivity")))
        assertFalse(shouldUseDocumentPicker("other.action.PICK_IMAGES", hyper))
        assertFalse(shouldUseDocumentPicker(MediaStore.ACTION_PICK_IMAGES, null))
    }

    @Test
    @Config(sdk = [35])
    fun hyperNativeSingleAndMultiplePickersStayNative() {
        val context = context()
        val component = ComponentName("com.android.photopicker", "com.android.photopicker.hyper.HyperMainActivity")
        val packageManager = shadowOf(context.packageManager)
        packageManager.addActivityIfNotPresent(component).exported = true
        packageManager.addIntentFilterForActivity(component, IntentFilter(MediaStore.ACTION_PICK_IMAGES).apply {
            addCategory(Intent.CATEGORY_DEFAULT)
        })
        assertFalse(usesDocumentPicker(context))
        assertFalse(usesDocumentPicker(context, maxItems = 30))
        val document = ActivityResultContracts.OpenMultipleDocuments().createIntent(context, arrayOf("image/*", "video/*"))
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, document.action)
        assertTrue(document.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertArrayEquals(arrayOf("image/*", "video/*"), document.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
    }

    @Test
    fun aDocumentFileReadsItsExactGivenBytesWithoutAMediaStoreFlag() {
        val provider = provider("original-files")
        val uri = Uri.parse("content://original-files/document/photo")
        val request = AndroidImportRequests.create(context(), uri, fromPhotoPicker = false)
        assertFalse(request.fromPhotoPicker)
        assertNull(request.openOriginal)
        assertTrue(request.permissionGranted)
        assertEquals("photo.jpg", request.displayName)
        assertArrayEquals(provider.file.readBytes(), request.openGiven().use { it.readBytes() })
        assertFalse(MediaStore.getRequireOriginal(provider.lastUri!!))
    }

    @Test
    fun bothPickerAndDirectMediaStoreSelectionsRequireOriginalBytesAndDisableTranscoding() {
        val provider = provider("media")
        val uri = Uri.parse("content://media/external/images/media/42")
        listOf(false, true).forEach { fromPicker ->
            val request = AndroidImportRequests.create(context(), uri, fromPicker)
            assertTrue(request.fromPhotoPicker)
            assertArrayEquals(provider.file.readBytes(), request.openGiven().use { it.readBytes() })
            assertArrayEquals(provider.file.readBytes(), request.openOriginal!!.invoke().use { it.readBytes() })
            assertTrue(MediaStore.getRequireOriginal(provider.lastUri!!))
            assertTrue(provider.lastOptions!!.getBoolean(MediaStore.EXTRA_ACCEPT_ORIGINAL_MEDIA_FORMAT))
        }
    }

    @Test fun pickerUrisWithMediaAuthorityNeverReceiveRequireOriginalOrGuessAnId() {
        listOf("content://media/picker/0/com.android.providers.media.photopicker/media/42",
            "content://media/picker_get_content/0/com.android.providers.media.photopicker/media/42",
            "content://media/picker_transcoded/0/media/42").forEach { text ->
            val uri = Uri.parse(text)
            assertFalse(AndroidImportRequests.isDirectMediaStoreUri(uri))
            assertNull(AndroidImportRequests.originalUri(uri, true) { error("must not infer a picker row") })
        }
    }

    @Test fun aGalleryRowReadsOriginalWhenMediaLocationIsGranted() {
        val provider = provider("media")
        val request = AndroidImportRequests.create(context(), Uri.parse("content://media/external_primary/images/media/42"),
            ImportOrigin.MediaStoreGallery)
        assertNotNull(request.openOriginal)
        assertArrayEquals(provider.file.readBytes(), request.openOriginal!!.invoke().use { it.readBytes() })
        assertTrue(MediaStore.getRequireOriginal(provider.lastUri!!))
    }

    @Test fun deniedMediaLocationStillAllowsAnAuthorizedGalleryStreamWithoutOriginalClaim() {
        val provider = provider("media")
        val context = context()
        shadowOf(context as android.app.Application).denyPermissions(MediaPermissions.ACCESS_MEDIA_LOCATION)
        val request = AndroidImportRequests.create(context, Uri.parse("content://media/external_primary/images/media/42"),
            ImportOrigin.MediaStoreGallery)
        assertNull(request.openOriginal)
        val imported = MediaImporter(temp.newFolder(), PreviewEncoder { _, _ -> "preview".toByteArray() },
            { _, _ -> false }, { _, _ -> CaptureTime.unknown() }).import(request)
        assertEquals(com.henrypann.jinbao365.archive.ImportProvenance.SystemProvided, imported.provenance)
        assertTrue(imported.wasDowngraded)
        assertFalse(MediaStore.getRequireOriginal(provider.lastUri!!))
    }

    @Test
    fun mediaDocumentsMapToTheGrantedMediaUriAndNeverFallBackToRedactedBytes() {
        val document = Uri.parse("content://com.android.providers.media.documents/document/image%3A42")
        val media = Uri.parse("content://media/external/images/media/42")
        val original = AndroidImportRequests.originalUri(document, false) {
            assertEquals(document, it)
            media
        }
        assertTrue(MediaStore.getRequireOriginal(original!!))
        assertEquals(media.path, original.path)
        assertNull(AndroidImportRequests.originalUri(document, false) { null })
        assertThrows(SecurityException::class.java) {
            AndroidImportRequests.originalUri(document, false) { throw SecurityException("grant revoked") }
        }
    }

    @Test
    fun externalStorageDocumentsUseTheOriginalPolicyWhenTheyHaveAMediaEquivalent() {
        val document = Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADownload%2Fphoto.jpg")
        val media = Uri.parse("content://media/external/images/media/42")
        assertTrue(MediaStore.getRequireOriginal(AndroidImportRequests.originalUri(document, false) { media }!!))
        assertNull(AndroidImportRequests.originalUri(document, false) { null })
    }

    @Test
    fun aDownloadsFileUsesTheExactMediaStoreFileIdWithOriginalFlags() {
        val doc = provider("com.android.providers.downloads.documents")
        val media = provider("media", doc.file)
        val uri = DocumentsContract.buildDocumentUri("com.android.providers.downloads.documents", "msf:42")
        val expected = Uri.parse("content://media/external/file/42")
        assertEquals(expected, AndroidImportRequests.downloadsFileUri(uri))
        val request = AndroidImportRequests.create(context(), uri, false)
        assertTrue(request.fromPhotoPicker)
        assertArrayEquals(doc.file.readBytes(), request.openGiven().use { it.readBytes() })
        assertArrayEquals(doc.file.readBytes(), request.openOriginal!!.invoke().use { it.readBytes() })
        assertEquals(expected.path, media.lastUri!!.path)
        assertTrue(MediaStore.getRequireOriginal(media.lastUri!!))
        assertTrue(media.lastOptions!!.getBoolean(MediaStore.EXTRA_ACCEPT_ORIGINAL_MEDIA_FORMAT))
        assertNotNull(doc.lastUri)
    }

    @Test
    fun unsupportedDownloadsIdsNeverGuessAFileOrReadTheRedactedDocumentStream() {
        val doc = provider("com.android.providers.downloads.documents")
        listOf("42", "raw:/storage/emulated/0/Download/photo.jpg", "msd:42", "msf:-42", "msf:0", "msf:42oops").forEach { id ->
            val uri = DocumentsContract.buildDocumentUri("com.android.providers.downloads.documents", id)
            assertNull(AndroidImportRequests.downloadsFileUri(uri))
            assertNull(AndroidImportRequests.create(context(), uri, false).openOriginal)
        }
        assertNull(doc.lastUri)
    }

    @Test
    fun aDownloadsMappingWithWrongMetadataOrAMissingMediaGrantRefusesTheImport() {
        val doc = provider("com.android.providers.downloads.documents")
        val media = provider("media", doc.file)
        val uri = DocumentsContract.buildDocumentUri("com.android.providers.downloads.documents", "msf:42")
        listOf<Pair<String, Any>>(OpenableColumns.DISPLAY_NAME to "other-photo.jpg",
            OpenableColumns.SIZE to (doc.file.length() + 1), MediaStore.MediaColumns.IS_DOWNLOAD to 0).forEach { (field, value) ->
            media.overrides[field] = value
            assertNull(AndroidImportRequests.create(context(), uri, false).openOriginal)
            media.overrides.clear()
        }
        media.denyQuery = true
        assertNull(AndroidImportRequests.create(context(), uri, false).openOriginal)
        assertNull(doc.lastUri)
        assertNull(media.lastUri)
    }

    @Test
    fun anUnknownPhotoPickerProviderCannotSilentlyIgnoreRequireOriginal() {
        val uri = Uri.parse("content://oem-picker/item/42")
        assertNull(AndroidImportRequests.originalUri(uri, true) { null })
        assertNull(AndroidImportRequests.originalUri(uri, false) { null })
    }

    @Test
    fun missingMediaLocationStillReadsSelectedDocumentWithoutOriginalClaim() {
        val provider = provider("original-files")
        val context = context()
        shadowOf(context as android.app.Application).denyPermissions(MediaPermissions.ACCESS_MEDIA_LOCATION)
        val request = AndroidImportRequests.create(context, Uri.parse("content://original-files/document/photo"), false)
        assertFalse(request.permissionGranted)
        val imported = MediaImporter(temp.newFolder(), PreviewEncoder { _, _ -> "preview".toByteArray() },
            { _, _ -> false }, { _, _ -> CaptureTime.unknown() }).import(request)
        assertEquals(com.henrypann.jinbao365.archive.ImportProvenance.FileSelected, imported.provenance)
        assertNotNull(provider.lastUri)
    }

    @Test
    fun revokedDeviceLocationDoesNotChangePerItemGrant() {
        val provider = provider("original-files")
        val context = context()
        val request = AndroidImportRequests.create(context, Uri.parse("content://original-files/document/photo"), false)
        shadowOf(context as android.app.Application).denyPermissions(
            MediaPermissions.ACCESS_COARSE_LOCATION, MediaPermissions.ACCESS_FINE_LOCATION)
        assertArrayEquals(provider.file.readBytes(), request.openGiven().use { it.readBytes() })
    }

    @Test
    fun permissionRequestsUseTheApisAvailableOnEachAndroidVersion() {
        val permissions = MediaPermissions.toRequest(Build.VERSION.SDK_INT)
        assertTrue(MediaPermissions.ACCESS_MEDIA_LOCATION in permissions)
        if (Build.VERSION.SDK_INT == 31) {
            assertEquals(listOf(MediaPermissions.ACCESS_MEDIA_LOCATION, MediaPermissions.READ_EXTERNAL_STORAGE), permissions)
            assertFalse(MediaPermissions.READ_MEDIA_IMAGES in permissions)
        } else {
            assertFalse(MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED in permissions)
            assertFalse(MediaPermissions.READ_EXTERNAL_STORAGE in permissions)
        }
    }

    private fun context(): Context = ApplicationProvider.getApplicationContext<android.app.Application>().also {
        shadowOf(it).grantPermissions(MediaPermissions.ACCESS_MEDIA_LOCATION, MediaPermissions.ACCESS_COARSE_LOCATION)
    }

    private fun provider(authority: String, file: File = temp.newFile().apply {
        writeBytes("original-with-GPS-and-video-trailer".toByteArray())
    }): BytesProvider {
        return BytesProvider(file).also {
            it.attachInfo(context(), ProviderInfo().apply { this.authority = authority; exported = true })
            ShadowContentResolver.registerProviderInternal(authority, it)
        }
    }

    private class BytesProvider(val file: File) : ContentProvider() {
        var lastUri: Uri? = null
        var lastOptions: Bundle? = null
        var denyQuery = false
        val overrides = mutableMapOf<String, Any>()
        override fun onCreate() = true
        override fun getType(uri: Uri) = "image/jpeg"
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            if (denyQuery) throw SecurityException("grant revoked")
            val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
            return MatrixCursor(columns).apply {
                addRow(columns.map { column -> overrides[column] ?: when (column) {
                    OpenableColumns.DISPLAY_NAME -> "photo.jpg"
                    OpenableColumns.SIZE -> file.length()
                    MediaStore.MediaColumns.IS_DOWNLOAD -> 1
                    else -> null
                } }.toTypedArray())
            }
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            lastUri = uri
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun openTypedAssetFile(uri: Uri, mimeTypeFilter: String, opts: Bundle?, signal: CancellationSignal?): AssetFileDescriptor {
            lastOptions = opts
            return AssetFileDescriptor(openFile(uri, "r"), 0, file.length())
        }
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    }
}

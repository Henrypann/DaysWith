package com.henrypann.jinbao365.media

import android.net.Uri

/** The user's entry point. Original fidelity is a separate, measured import result. */
enum class ImportOrigin { Camera, PhotoPicker, Document, MediaStoreGallery }

/** Each selected URI retains its own grant type and position across mixed picker sources. */
data class MediaSelection(val uri: Uri, val origin: ImportOrigin)

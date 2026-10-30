package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonPrimitive

/** Evidence about the bytes saved by an import, never a claim inferred from missing GPS. */
enum class ImportProvenance(val wireValue: String, val label: String) {
    Camera("camera", "App内拍摄"),
    VerifiedOriginal("verifiedOriginal", "已确认原件"),
    SystemProvided("systemProvided", "系统提供版本"),
    FileSelected("fileSelected", "文件导入"),
    Unknown("unknown", "来源未知");

    companion object {
        const val EXTENSION_KEY = "importProvenance"
        fun fromWire(value: String?): ImportProvenance = entries.firstOrNull { it.wireValue == value } ?: Unknown
    }
}

val MediaAsset.importProvenance: ImportProvenance
    get() = ImportProvenance.fromWire((extensions[ImportProvenance.EXTENSION_KEY]?.value as? JsonPrimitive)
        ?.takeIf { it.isString }?.content)

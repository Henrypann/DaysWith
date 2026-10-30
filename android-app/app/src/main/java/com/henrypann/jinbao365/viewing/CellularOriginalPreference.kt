package com.henrypann.jinbao365.viewing

import java.io.File

/**
 * Whether partner originals may download on a metered network without asking.
 * Independent of backup's cellular policy: this file is the only store.
 */
internal class CellularOriginalPreference(private val file: File) {
    fun allow(): Boolean = runCatching { file.isFile && file.readText() == "1" }.getOrDefault(false)

    fun setAllow(allow: Boolean) {
        val directory = file.parentFile ?: error("无法保存流量查看设置")
        directory.mkdirs()
        val temporary = File(directory, file.name + ".tmp")
        temporary.writeText(if (allow) "1" else "0")
        if (!temporary.renameTo(file)) {
            temporary.delete()
            error("无法保存流量查看设置")
        }
    }
}

package com.henrypann.jinbao365.data

import android.content.Context
import android.util.AtomicFile
import java.io.File

/** The folder is a protocol identity, fixed for this installation after confirmation. */
enum class ParentIdentity(val label: String, val folder: String) {
    Dad("爸爸", "dad"), Mom("妈妈", "mom");
    val prefix: String get() = "life/v1/$folder/"
    val other: ParentIdentity get() = if (this == Dad) Mom else Dad
}

class ParentIdentityStore(private val directory: File) {
    constructor(context: Context) : this(context.noBackupFilesDir)
    private val file = AtomicFile(File(directory, "parent-identity-v1"))
    val parent: ParentIdentity?
        @Synchronized get() = if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) null
            else file.openRead().bufferedReader().use { reader ->
                val value = reader.readText()
                ParentIdentity.entries.firstOrNull { it.folder == value }
                    ?: error("这台手机的身份记录无法读取，请保留应用数据。")
            }

    @Synchronized fun confirm(value: ParentIdentity) {
        val existing = parent
        check(existing == null || existing == value) { "这台手机的署名已经确定，不能修改。" }
        if (existing != null) return
        directory.mkdirs()
        val stream = file.startWrite()
        try {
            stream.write(value.folder.toByteArray(Charsets.UTF_8))
            stream.fd.sync()
            file.finishWrite(stream)
            check(parent == value) { "署名没有保存成功，请重试。" }
        } catch (failure: Exception) {
            file.failWrite(stream)
            throw failure
        }
    }
}

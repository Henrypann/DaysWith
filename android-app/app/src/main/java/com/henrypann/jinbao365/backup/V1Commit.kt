package com.henrypann.jinbao365.backup

data class V1Commit(
    val version: Int = 1,
    val sequence: Long,
    val parentHash: String? = null,
    val writerDeviceID: String,
    val kind: String = "snapshot",
    val manifestHash: String,
    val manifestKey: String,
    val createdAt: Long,
    val requestID: String,
)

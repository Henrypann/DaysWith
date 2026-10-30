package com.henrypann.jinbao365

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val migrationWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.henrypann.jinbao365/legacy_upgrade")
            .setMethodCallHandler { call, result ->
                if (call.method !in setOf("prepareMigration", "readLegacyCredentials")) {
                    result.notImplemented()
                } else migrationWorker.execute {
                    try {
                        val reader = LegacyUpgrade(applicationContext)
                        val value = when (call.method) {
                            "prepareMigration" -> reader.prepare(checkNotNull(call.argument<Boolean>("testBuild")))
                            else -> reader.readCredentials(checkNotNull(call.argument<String>("bucket")),
                                checkNotNull(call.argument<String>("region")))
                        }
                        runOnUiThread { result.success(value) }
                    } catch (_: Exception) {
                        // Never include source values, ciphertext, exception text or credentials in channel errors/logs.
                        runOnUiThread { result.error("legacy_upgrade_blocked",
                            "旧版资料暂时无法安全升级，原始资料和连接已保留。请保留应用数据后重试。", null) }
                    }
                }
            }
    }

    override fun onDestroy() {
        migrationWorker.shutdown()
        super.onDestroy()
    }
}

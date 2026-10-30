import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Use the native Android app's signing inputs for an in-place Flutter upgrade.
// Local values may override the native project's ignored local.properties.
val releaseSigningProperties = Properties().apply {
    listOf(rootProject.file("../../../android-app/local.properties"), rootProject.file("local.properties"))
        .filter { it.isFile }.forEach { file -> file.inputStream().use(::load) }
}
fun releaseSigningValue(key: String): String? = releaseSigningProperties.getProperty(key)
    ?.takeIf { it.isNotBlank() } ?: System.getenv(key)?.takeIf { it.isNotBlank() }
val releaseStoreFile = releaseSigningValue("JINBAO_RELEASE_STORE_FILE")
val releaseStorePassword = releaseSigningValue("JINBAO_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("JINBAO_RELEASE_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("JINBAO_RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
    .all { it != null }

android {
    namespace = "com.henrypann.jinbao365"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep the installed native app's UID, private files and Keystore entries.
        applicationId = "com.henrypann.jinbao365"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                val configured = File(requireNotNull(releaseStoreFile))
                storeFile = if (configured.isAbsolute) configured
                    else rootProject.file("../../../android-app").resolve(configured)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Never silently replace a distributed signing identity with debug keys.
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}


dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

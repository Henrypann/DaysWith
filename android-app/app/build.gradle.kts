import java.io.File
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

val localSigningProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use(::load)
}
fun releaseSigningValue(key: String): String? = localSigningProperties.getProperty(key)
    ?.takeIf { it.isNotBlank() } ?: System.getenv(key)?.takeIf { it.isNotBlank() }
val releaseStoreFile = releaseSigningValue("JINBAO_RELEASE_STORE_FILE")
val releaseStorePassword = releaseSigningValue("JINBAO_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("JINBAO_RELEASE_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("JINBAO_RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
    .all { it != null }

android {
    namespace = "com.henrypann.jinbao365"
    compileSdk = 37
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "com.henrypann.jinbao365"
        minSdk = 29
        targetSdk = 35
        versionCode = 10
        versionName = "2.2.7"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        create("release") {
            // A partially configured checkout can still assemble an unsigned release.
            if (hasReleaseSigning) {
                val configured = File(requireNotNull(releaseStoreFile))
                storeFile = if (configured.isAbsolute) configured else rootProject.file(configured)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        create("preview") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".preview"
            versionNameSuffix = "-preview"
            matchingFallbacks += "debug"
        }
        getByName("release") {
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
    }
    testBuildType = providers.gradleProperty("deviceTestBuildType").orElse("debug").get()
    sourceSets.getByName("preview").kotlin.directories += "src/debug/java"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.isReturnDefaultValues = true
        // Optional flat directory of cached Robolectric SDK jars for fully offline test runs.
        unitTests.all {
            System.getenv("ROBOLECTRIC_DEPENDENCY_DIR")?.let { directory ->
                it.systemProperty("robolectric.offline", "true")
                it.systemProperty("robolectric.dependency.dir", directory)
            }
        }
    }
    ksp {
        arg("room.schemaLocation", "$projectDir/schemas")
    }
}

androidComponents.beforeVariants(androidComponents.selector().withBuildType("preview")) {
    it.hostTests[com.android.build.api.variant.HostTestBuilder.UNIT_TEST_TYPE]?.enable = true
}

dependencies {
    implementation(libs.androidx.core)
    implementation(libs.androidx.exifinterface)
    implementation(libs.androidx.activity.compose)
    implementation(platform("androidx.compose:compose-bom:${libs.versions.composeBom.get()}"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation(libs.androidx.room.runtime)
    implementation(libs.kotlinx.serialization.json)
    ksp(libs.androidx.room.compiler)
    debugImplementation("androidx.compose.ui:ui-tooling")
    androidTestImplementation(platform("androidx.compose:compose-bom:${libs.versions.composeBom.get()}"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    // Espresso 3.7 uses the public input service rather than the removed InputManager.getInstance.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    "previewImplementation"("androidx.compose.ui:ui-test-manifest")
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(platform("androidx.compose:compose-bom:${libs.versions.composeBom.get()}"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.test.espresso:espresso-core:3.7.0")
}

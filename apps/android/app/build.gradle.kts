plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.google.services)
}

android {
    namespace = "com.voiid.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.voiid.app"
        minSdk = 24          // Android 7.0+ — broad device coverage (older-OS fallbacks below)
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables { useSupportLibrary = true }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // The app carries TWO WebRTC native builds (Stream's libjingle for 1:1 +
    // LiveKit's liblkjingle for group calls) plus the e2e-core Rust lib, across 4
    // ABIs — a universal APK is ~130 MB. Split RELEASE APKs by ABI so each device
    // build carries only its own ABI (~40 MB). Gated to release tasks ONLY, so
    // debug builds (and the app-debug.apk verification path) are untouched.
    //
    // PREFERRED distribution is the App Bundle (`./gradlew bundleRelease`) — Play
    // then delivers only the device's ABI automatically with no per-ABI APK/version
    // -code juggling. These splits are for DIRECT APK distribution (sideload / other
    // stores). See docs/WEBRTC_VERSIONS.md.
    splits {
        abi {
            isEnable = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
            isUniversalApk = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true   // exposes BuildConfig.VERSION_NAME for force-update gating
    }
}

// Give each per-ABI release APK a distinct versionCode — Play rejects multiple APKs
// that share one. Offset = base*10 + abiRank, so arm64 always outranks armeabi on a
// device that could run either. No-op for the universal debug APK (no ABI filter).
androidComponents {
    val abiRank = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86" to 3, "x86_64" to 4)
    onVariants { variant ->
        variant.outputs.forEach { output ->
            val abi = output.filters.find { it.filterType == com.android.build.api.variant.FilterConfiguration.FilterType.ABI }?.identifier
            val base = output.versionCode.get() ?: 1
            if (abi != null) {
                output.versionCode.set(base * 10 + (abiRank[abi] ?: 0))
            }
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.foundation)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.coil.compose)

    // Networking + auth (VOIID backend)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.security.crypto)

    // Firebase Phone Auth (OTP sender/verifier on-device)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.auth)
    // Firebase Cloud Messaging — receives the content-free "wake" data push; the
    // FirebaseMessagingService fetches + decrypts locally and posts the notification.
    implementation(libs.firebase.messaging)
    implementation(libs.kotlinx.coroutines.play.services)   // Task.await()

    // Google Sign-In — authorizes the least-privilege drive.appdata OAuth scope so the
    // encrypted backup blob can be stored in the user's own private Drive appDataFolder.
    // GoogleAuthUtil (in play-services-auth-base) mints the OAuth access token; the Drive
    // v3 REST transfer itself rides the existing OkHttp (no heavy Drive client library).
    implementation(libs.play.services.auth)

    // E2E core (Rust via uniffi). The generated Kotlin in uniffi/voiid/voiid.kt
    // uses JNA to call into jniLibs/<abi>/libvoiid_e2e_core.so. Must be the @aar
    // (it ships the Android-native JNA dispatch library); the plain jar won't load.
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    // WebRTC engine for real 1:1 voice/video calls. Stream's maintained build of
    // libwebrtc, published on Maven Central under the original `org.webrtc` package.
    implementation(libs.stream.webrtc.android)

    // LiveKit SFU client for group calls. It does NOT collide with the Stream WebRTC
    // build above: LiveKit depends on io.github.webrtc-sdk:android-prefixed, whose
    // classes are relocated to `livekit.org.webrtc` (zero classes under `org.webrtc`)
    // and whose native library is `liblkjingle_peerconnection_so.so` (vs Stream's
    // `libjingle_peerconnection_so.so`). Both stacks coexist — no exclusions needed.
    implementation(libs.livekit.android)

    debugImplementation(libs.androidx.ui.tooling)

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
}

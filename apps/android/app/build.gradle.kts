import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.google.services)
    alias(libs.plugins.ksp)          // Room’s annotation processor
}


// ── ENVIRONMENT BOUNDARY (Q03) ────────────────────────────────────────────────────
//
// Both clients used to hardcode `https://api-dev.voiid.app`, with nothing anywhere assigning
// anything else. A release APK would have been built against the development backend, signed and
// shipped, and the only thing preventing that was somebody remembering to edit a constant.
//
// The endpoints are build configuration now. Debug keeps a working default so local development
// is unchanged; RELEASE HAS NO DEFAULT AT ALL and fails the build if it is not supplied. The
// production hostname is deliberately not written down here — this audit does not know it, and
// guessing one would replace a visible misconfiguration with an invisible one.
//
// Supply it per build:  ./gradlew assembleRelease -PVOIID_API_BASE_URL=https://… -PVOIID_WS_URL=wss://…
// or via the VOIID_API_BASE_URL / VOIID_WS_URL environment variables.
fun requireReleaseEndpoint(name: String, wsScheme: Boolean): String {
    val value = (project.findProperty(name) as String?) ?: System.getenv(name)
    if (value.isNullOrBlank()) {
        throw GradleException(
            "$name is not set. A release build must be told which backend it talks to; there is " +
            "no default, because the only safe default would be the development host. Pass " +
            "-P$name=… or set it in the environment."
        )
    }
    // A release pointing at the dev box or a laptop is the exact failure this exists to stop,
    // and it is worth catching at build time rather than in a store review.
    val forbidden = listOf("api-dev.voiid.app", "localhost", "127.0.0.1", "10.0.2.2")
    if (forbidden.any { value.contains(it) }) {
        throw GradleException("$name points at a development host ($value); a release must not.")
    }
    val required = if (wsScheme) "wss://" else "https://"
    if (!value.startsWith(required)) {
        throw GradleException("$name must use $required (got $value): a release never talks in plaintext.")
    }
    return value
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

        // Maps API key is a BUILD-TIME secret supplied by the developer, never committed.
        // Sources, in order: -PMAPS_API_KEY, local.properties (read explicitly below — plain
        // Gradle does NOT fold this file into project properties; that's an Android Studio
        // IDE-only convenience for sdk.dir), MAPS_API_KEY env var.
        //
        // An absent key is a SUPPORTED state, not a build failure: with an empty key the
        // Maps SDK renders a blank grey tile grid and logs an auth error nobody sees, which
        // is worse than no map at all. MAPS_CONFIGURED lets the UI refuse to instantiate
        // GoogleMap and render an explicit "Maps aren't set up in this build" card instead,
        // while location sharing itself keeps working end to end (coordinates + Open in Maps).
        // See docs/LOCATION.md §7.
        val localProps = Properties()
        val localPropsFile = rootProject.file("local.properties")
        if (localPropsFile.exists()) {
            localPropsFile.inputStream().use { localProps.load(it) }
        }
        val mapsKey: String = (project.findProperty("MAPS_API_KEY") as String?)
            ?: localProps.getProperty("MAPS_API_KEY")
            ?: System.getenv("MAPS_API_KEY")
            ?: ""
        manifestPlaceholders["MAPS_API_KEY"] = mapsKey
        buildConfigField("boolean", "MAPS_CONFIGURED", mapsKey.isNotBlank().toString())
    }

    buildTypes {
        debug {
            // Local development, unchanged. Overridable the same way release is, so pointing a
            // debug build at a laptop or a staging box needs no source edit.
            val debugApi = (project.findProperty("VOIID_API_BASE_URL") as String?)
                ?: System.getenv("VOIID_API_BASE_URL") ?: "https://api-dev.voiid.app"
            val debugWs = (project.findProperty("VOIID_WS_URL") as String?)
                ?: System.getenv("VOIID_WS_URL") ?: "wss://api-dev.voiid.app/ws"
            buildConfigField("String", "VOIID_API_BASE_URL", "\"$debugApi\"")
            buildConfigField("String", "VOIID_WS_URL", "\"$debugWs\"")
        }
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Evaluated lazily: reading these at configuration time would make EVERY gradle
            // invocation — including `testDebugUnitTest` — fail when the release endpoints are
            // unset, which would make local development impossible.
            buildConfigField("String", "VOIID_API_BASE_URL",
                "\"${if (gradle.startParameter.taskNames.any { it.contains("elease", true) }) requireReleaseEndpoint("VOIID_API_BASE_URL", false) else ""}\"")
            buildConfigField("String", "VOIID_WS_URL",
                "\"${if (gradle.startParameter.taskNames.any { it.contains("elease", true) }) requireReleaseEndpoint("VOIID_WS_URL", true) else ""}\"")
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
        // minSdk is 24 and the app uses java.time, which arrived in API 26 (A03). Without this
        // every java.time call throws NoClassDefFoundError on API 24/25 — and because the call
        // sites wrapped it in runCatching, the error was swallowed and every timestamp silently
        // became the current time. Lint had been reporting 37 of these to nobody.
        isCoreLibraryDesugaringEnabled = true
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true   // exposes BuildConfig.VERSION_NAME for force-update gating
    }
    lint {
        // False positive that otherwise fails EVERY release build (lintVitalRelease):
        // MainActivity is a Compose ComponentActivity and gets registerForActivityResult
        // directly from androidx.activity — it uses no Fragments, so the check's
        // "upgrade Fragment to 1.3.0" requirement doesn't apply. This lint misfires on
        // Compose/ComponentActivity apps. Scoped to this one check only; all other lint
        // (including release-vital) stays enabled.
        disable += "InvalidFragmentVersionForActivityResult"
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

// BackupRulesTest reads the SHIPPED res/xml rules and the SHIPPED sources off disk, because
// the thing it is checking is the policy that actually ships, not a copy of it in a fixture.
// Gradle cannot see those reads, so without declaring them the task stays UP-TO-DATE when the
// rules change — the guard would pass forever while the policy rotted underneath it. This was
// caught by changing a rule and watching the test not run.
// Where Room writes the exported schema JSON (A04). Committed under app/schemas so an upgrade
// path has a record of what actually shipped to migrate from — without it, a migration can only
// be checked against the current code's idea of the old schema.
ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}

tasks.withType<Test>().configureEach {
    inputs.dir("src/main/res/xml")
        .withPropertyName("backupRuleFiles")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    // RoomMigrationPolicyTest reads the exported schemas off disk, and Gradle cannot see that.
    // Without declaring it the task stays UP-TO-DATE when a schema changes and the guard rots.
    inputs.dir("schemas")
        .withPropertyName("roomSchemas")
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .optional()
    // Same reason, for the guards that read the manifest and this build file (Q03). Caught by
    // changing all three and watching the tests report byte-identical stale results.
    inputs.file("src/main/AndroidManifest.xml")
        .withPropertyName("appManifest")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.file("build.gradle.kts")
        .withPropertyName("appBuildScript")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir("src/debug")
        .withPropertyName("debugSourceSet")
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .optional()
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)

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

    // Vetted QR ENCODER (pure-Java ZXing core, no Play Services) for the safety-number QR.
    implementation(libs.zxing.core)
    implementation(libs.coil.gif)

    // Networking + auth (VOIID backend)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.security.crypto)

    // Room — the local-first SQLite store (users / conversations / messages /
    // call_history). The UI reads THIS; the network is a sync peer, not the store.
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    // CameraX — in-app story capture. NSCameraUsageDescription / the CAMERA permission are
    // already declared and requested at onboarding, so no permission plumbing changes.
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    // Recording, not just stills — see ClipCameraView. The clip composer used to hand off to
    // the system camera intent because this artifact was missing.
    implementation(libs.androidx.camera.video)

    // Media3 — Clips: ExoPlayer for the reels player, Transformer + Effect for the
    // editor's trim/filter export. See docs/CLIPS.md §5.3 for why this is the correct
    // counterpart to iOS's AVFoundation + Core Image (there is no API on either
    // platform that enumerates the system photo-app filters).
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.ui)
    implementation(libs.androidx.media3.transformer)
    implementation(libs.androidx.media3.effect)
    implementation(libs.androidx.media3.common)

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

    // Location sharing (docs/LOCATION.md). Fused provider for the fixes, Maps SDK +
    // Maps Compose for the bubble thumbnail (lite mode) and the detail map. ~300 KB on a
    // ~140 MB APK, and GMS is already a dependency of Firebase/auth above.
    implementation(libs.play.services.location)
    implementation(libs.play.services.maps)
    implementation(libs.maps.compose)
    // Map-tab place search. Uses the SAME api key as Maps; needs "Places API (New)" enabled
    // on that key or every request fails (see MapPlaceSearch, which degrades quietly).
    implementation(libs.places)

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

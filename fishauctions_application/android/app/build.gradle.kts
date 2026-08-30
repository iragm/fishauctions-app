import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by android/key.properties, which is gitignored and
// supplied out of band (locally by the developer; in CI written from secrets
// before the release build). When it's absent — most local/dev builds and PR
// CI — the release build falls back to debug signing so it still compiles; that
// APK just isn't Play-Store-uploadable.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseSigning) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "com.fishauctions.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications, which compiles against
        // java.time. minSdk 28 predates it on the platform, so the app module
        // has to desugar too — the plugin enabling it in its own module only
        // covers the plugin's own classes.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.fishauctions.app"
        // Square Mobile Payments SDK requires minSdk 28. Tap to Pay on Android
        // itself needs API 31+; on 28-30 the app installs but Tap to Pay reports
        // the device as unsupported at runtime.
        minSdk = maxOf(28, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        resources {
            // Square's mobile-payments-sdk-internals 2.6.0 drags in the *JVM*
            // SQLDelight driver (org.xerial:sqlite-jdbc — see the -dontwarn
            // block in proguard-rules.pro), whose jar carries desktop JNI
            // binaries as plain java resources. AGP's defaults drop the .so
            // files but not the Windows .dll / macOS .dylib ones, so 6.2 MB of
            // them were being packaged into every APK/AAB (verified in
            // app-staging-debug.apk). Nothing on Android can load them.
            excludes += "org/sqlite/native/**"
        }
    }

    flavorDimensions.add("env")

    productFlavors {
        // appLinkHost is the host this flavor would claim Android App Links
        // for (the <data> element in AndroidManifest.xml). Currently unused:
        // the intent filter that reads it is commented out, because claiming
        // the domain is a product decision that has been answered "not yet" —
        // see the long note in AndroidManifest.xml for why it is off and the
        // order to turn it on. Kept here so that day is one uncomment.
        //
        // It MUST match the backend EnvironmentConfig.apiBaseUrl resolves to
        // for the same FLAVOR dart-define, or the app would offer to open
        // links belonging to a deployment it can't sign in to. Each host's
        // /.well-known/assetlinks.json (served by the backend from
        // ANDROID_APP_LINKS) has to list this flavor's applicationId and
        // signing-cert SHA-256 or verification fails and the links keep
        // opening in the browser.
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLinkHost"] = "staging.auction.fish"
        }
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
            manifestPlaceholders["appLinkHost"] = "staging.auction.fish"
        }
        create("prod") {
            dimension = "env"
            manifestPlaceholders["appLinkHost"] = "auction.fish"
        }
    }

    signingConfigs {
        // Only defined when key.properties is present; otherwise the release
        // build type below falls back to the debug signing config. storeFile is
        // resolved relative to this module (android/app/).
        if (hasReleaseSigning) {
            create("release") {
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        debug {
            isDebuggable = true
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Real keystore when key.properties is present (Play Store builds),
            // otherwise debug signing so local/PR-CI release builds still work.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
    // Keep in sync with the version flutter_local_notifications' own module
    // pulls (android/build.gradle) — a lower one here loses the resolution.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // MainActivity initializes the Square SDK just-in-time (from the app id the
    // backend returns per invoice), so the app module needs the SDK on its
    // compile classpath. The square_mobile_payments_sdk plugin pulls the same
    // artifact as `implementation`, which doesn't expose it here. Keep this
    // version in sync with squareSdkVersion in the plugin's android/build.gradle
    // (currently 2.6.0); the Square maven repo is declared in the root
    // android/build.gradle.kts.
    implementation("com.squareup.sdk:mobile-payments-sdk:2.6.0")

    // AR lot mode's camera pipeline (ar/): ARCore owns the camera for
    // visual-inertial pose tracking (replaces the pedometer's coarse
    // stride-counted odometry) and hands its frames to ML Kit for QR
    // detection — the same detection engine the mobile_scanner package used
    // for this screen, so detection quality is unchanged. See
    // ar/ArSessionManager.kt for why these two must share one camera client.
    implementation("com.google.ar:core:1.54.0")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
}

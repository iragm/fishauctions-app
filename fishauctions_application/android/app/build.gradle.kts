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

    flavorDimensions.add("env")

    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
        }
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
        }
        create("prod") {
            dimension = "env"
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
    // MainActivity initializes the Square SDK just-in-time (from the app id the
    // backend returns per invoice), so the app module needs the SDK on its
    // compile classpath. The square_mobile_payments_sdk plugin pulls the same
    // artifact as `implementation`, which doesn't expose it here. Keep this
    // version in sync with squareSdkVersion in the plugin's android/build.gradle
    // (currently 2.5.0); the Square maven repo is declared in the root
    // android/build.gradle.kts.
    implementation("com.squareup.sdk:mobile-payments-sdk:2.5.0")
}

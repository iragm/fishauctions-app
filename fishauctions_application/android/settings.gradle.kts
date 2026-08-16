pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// AGP is deliberately held on the 8.x line, and must not go to 9.x again until
// Square ships a fix. AGP 9.0 removed `targetSdk` from the *library* DSL
// (`LibraryBaseFlavor.setTargetSdk` — verified absent from the 9.0.1, 9.2.1 and
// 9.3.1 jars, present in 8.13.2), and square_mobile_payments_sdk's Android
// module still sets it, so every AGP 9 build dies while configuring the plugin.
// Square documents "AGP 8.4.2 or later" and does not mention AGP 9 at all.
//
// This is not a stale pin: 8.13.2 is the newest 8.x. Flutter 3.44.1 requires
// Gradle >= 8.13 for AGP 8.13, so the 9.7.0 wrapper above stays as is. The
// weekly updater enforces the ceiling (GRADLE_CEILING in dependencies.yml) so
// patch releases still flow but 9.x can't come back on its own.
//
// Note that Flutter 3.44.1 itself only knows AGP up to 9.1 and KGP up to
// 2.3.20 (maxKnownAndSupportedAgpVersion / maxKnownAndSupportedKgpVersion in
// flutter_tools/lib/src/android/gradle_utils.dart) — 9.3.1 and Kotlin 2.4.10
// were both past what this SDK supports, courtesy of unattended bumps.
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.4.10" apply false
}

include(":app")

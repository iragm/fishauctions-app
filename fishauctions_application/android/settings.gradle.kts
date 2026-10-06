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

// AGP 9, again. It was held on 8.13.2 from 2026-08-16 because AGP 9.0 removed
// `targetSdk` from the *library* DSL and square_mobile_payments_sdk's Android
// module set it, so every AGP 9 build died configuring that plugin. Square
// 2026.8.4 dropped the line ("Removing targetSdk = 36 … in order to setup
// target in app level"), and pubspec.yaml's ^2026.10.1 floor keeps it out.
//
// 9.3.1 on the 9.7 wrapper is the pair this project last built with before
// the hold (2026-07-28 .. 08-16), so this is a return to a known toolchain,
// not a new one. The weekly updater moves both from here; the 8.x hold's
// second half — the wrapper capped at 9.5.x because Gradle 9.6 removed an
// internal API AGP 8.x calls — goes with it.
//
// Note that Flutter 3.44.1 itself only knows AGP up to 9.1 and KGP up to
// 2.3.20 (maxKnownAndSupportedAgpVersion / maxKnownAndSupportedKgpVersion in
// flutter_tools/lib/src/android/gradle_utils.dart). Newer is accepted — it
// treats an unknown AGP as valid on Gradle >= 9.1 — but is past what that SDK
// was tested against.
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")

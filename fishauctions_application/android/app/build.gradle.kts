plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        debug {
            isDebuggable = true
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // TODO: Add your own signing config for the release build.
            signingConfig = signingConfigs.getByName("debug")
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

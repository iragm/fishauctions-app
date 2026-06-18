# Flutter Build Variants

The Android app supports three build variants (flavors). The Gradle `--flavor`
sets the Android `applicationId`, and `--dart-define=FLAVOR=<flavor>` selects the
backend URL in Dart.

> **Always pass both `--flavor` and `--dart-define=FLAVOR=` together.** The
> Gradle flavor does **not** reach Dart code, so a `prod` build without
> `--dart-define=FLAVOR=prod` would silently talk to the staging backend. See
> `lib/config/environment.dart`.

## Development (`dev`)
- Package ID: `com.fishauctions.app.dev`
- API: `https://staging.auction.fish` (shared with staging — convenient for
  on-device debugging, since `localhost` isn't reachable from a phone)
- Logging: verbose (request/response bodies)
- Run: `flutter run --flavor dev --dart-define=FLAVOR=dev`

## Staging (`staging`)
- Package ID: `com.fishauctions.app.staging`
- API: `https://staging.auction.fish`
- Logging: normal
- Run: `flutter run --flavor staging --dart-define=FLAVOR=staging`

## Production (`prod`)
- Package ID: `com.fishauctions.app`
- API: `https://auction.fish`
- Logging: errors only
- Run: `flutter run --flavor prod --dart-define=FLAVOR=prod`

## Building releases

Requires **JDK 17** (Android Gradle Plugin 9). Set `JAVA_HOME` accordingly.

```bash
# Production APK (what CI builds on push to master)
flutter build apk --release --flavor prod --dart-define=FLAVOR=prod

# Smaller per-ABI APKs (the fat APK is ~178MB because of the Square native libs)
flutter build apk --release --flavor prod --dart-define=FLAVOR=prod --split-per-abi

# App bundle for the Play Store (later — needs real release signing)
flutter build appbundle --release --flavor prod --dart-define=FLAVOR=prod
```

> Release builds currently use the **debug** signing config (see
> `android/app/build.gradle.kts`). Replace it with a real keystore before any
> Play Store upload.

## Minimum Android version

`minSdk` is **28** (required by the Square Mobile Payments SDK). Tap to Pay
itself needs API 31+; on 28–30 the app installs but Tap to Pay reports the
device as unsupported at runtime.

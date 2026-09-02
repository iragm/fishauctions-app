# Build variants

Three Android flavors. `--flavor` sets the Android `applicationId`; `--dart-define=FLAVOR=` selects the backend URL in Dart.

> **Always pass both.** The Gradle flavor does not reach Dart, so a `prod` build without `--dart-define=FLAVOR=prod` silently talks to staging. See `lib/config/environment.dart`.

| Flavor | applicationId | API | Logging |
|---|---|---|---|
| `dev` | `com.fishauctions.app.dev` | `staging.auction.fish` | verbose (bodies) |
| `staging` | `com.fishauctions.app.staging` | `staging.auction.fish` | normal |
| `prod` | `com.fishauctions.app` | `auction.fish` | errors only |

dev shares the staging backend because a phone can't reach `localhost`.

**iOS has no flavors** — no Xcode schemes, so environment selection is dart-define only.

## Releases

```bash
flutter build apk --release --flavor prod --dart-define=FLAVOR=prod
flutter build apk --release --flavor prod --dart-define=FLAVOR=prod --split-per-abi   # fat APK is ~178MB (Square native libs)
flutter build appbundle --release --flavor prod --dart-define=FLAVOR=prod
```

Signing is wired in CI (keystore from repo secrets; the release workflow refuses to build unsigned). **A local `--release` build still falls back to debug signing** unless you create `android/key.properties` yourself — which also means it can't do Google sign-in, since that matches on signing-certificate SHA-1.

## Minimum Android version

`minSdk` is **28** (Square Mobile Payments SDK floor). Tap to Pay itself needs API 31+; on 28–30 the app installs and Tap to Pay reports the device as unsupported at runtime.

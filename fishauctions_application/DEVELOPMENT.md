# Development

Architecture and the `/api/mobile/` contract are in `CLAUDE.md`. This is just how to build and run.

## Layout

```
lib/{config,constants,models,screens,services,utils,widgets}/
```

Riverpod (state) · go_router · Dio · freezed + json_serializable · flutter_secure_storage.

## Commands

```bash
flutter run --flavor dev --dart-define=FLAVOR=dev     # both flags, always — see BUILD_VARIANTS.md
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
dart format .
```

Run the CI gates locally before pushing:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

## CI

`.github/workflows/` at the repo root. **ci.yml** runs those three gates plus a generated-code freshness check on every PR and push to main. **android-release.yml** and **ios-release.yml** are manual. Details, including the build traps worth knowing before you touch Gradle or Xcode, are in `CLAUDE.md`.

# FishAuctions Development Guide

## Project Structure

```
lib/
├── config/          # Configuration (environment, constants for non-API)
├── constants/       # App-wide constants
├── models/          # Data models, DTOs
├── screens/         # Full-page widgets / routes
├── services/        # Business logic, API calls, repositories
├── utils/           # Helper functions, utilities
└── widgets/         # Reusable component widgets
```

## State Management

This project uses **Riverpod** for state management. It's modern, strongly typed, and integrates well with Dart/Flutter.

### Why Riverpod?
- Provider-based (functions, not builder widgets)
- Testable by default
- Type-safe
- Test-friendly dependency injection

## Build Variants

Three flavors support different environments:
- `dev`: Local development with easy debugging
- `staging`: Staging environment for QA
- `prod`: Production builds

Run with: `flutter run --flavor dev`

See `BUILD_VARIANTS.md` for details.

## Code Quality

- Strict linting enabled via `analysis_options.yaml`
- Run `flutter analyze` before committing
- Use `flutter pub run build_runner build` to generate code for Riverpod

## HTTP Client

All API requests use **Dio** with interceptors for:
- Error handling
- Request/response logging
- Token management (future)

Place API services in `lib/services/`.

## Getting Started

1. `flutter pub get` - Already done, but run this if you pull new changes
2. Create screens in `lib/screens/`
3. Define models in `lib/models/`
4. Implement logic in `lib/services/`
5. Use Riverpod providers for state

## Useful Commands

```bash
# Run dev build (always pass --dart-define=FLAVOR with --flavor; see BUILD_VARIANTS.md)
flutter run --flavor dev --dart-define=FLAVOR=dev

# Analyze code quality
flutter analyze

# Generate code (freezed / json_serializable / Riverpod)
dart run build_runner build --delete-conflicting-outputs

# Build release APK (requires JDK 17)
flutter build apk --release --flavor prod --dart-define=FLAVOR=prod

# Format code
dart format .

# Run tests
flutter test
```

## CI

GitHub Actions live in `.github/workflows/` at the repo root:

- **ci.yml** — on every PR (and pushes to master): `flutter pub get`, a
  generated-code freshness check, `dart format --set-exit-if-changed`,
  `flutter analyze`, and `flutter test`.
- **android-release.yml** — on push to master: builds the prod release APK and
  uploads it as a build artifact. Play Store upload and iOS/macOS builds are
  scaffolded but intentionally disabled until signing is set up.

Run the same gates locally before pushing:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

That's it! Keep the structure clean and you'll scale easily to hundreds of features.

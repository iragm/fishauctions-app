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
# Run dev build
flutter run --flavor dev

# Analyze code quality
flutter analyze

# Generate code (Riverpod)
flutter pub run build_runner build

# Build release APK
flutter build apk --flavor prod --release

# Format code
flutter format .
```

That's it! Keep the structure clean and you'll scale easily to hundreds of features.

# Flutter Build Variants

The Android app supports three build variants (flavors):

## Development (`dev`)
- Package ID: `com.fishauctions.app.dev`
- API: `http://localhost:8000` (local development)
- Logging: Verbose
- Build: `flutter run --flavor dev`

## Staging (`staging`)
- Package ID: `com.fishauctions.app.staging`
- API: `https://staging-api.fishauctions.com`
- Logging: Normal
- Build: `flutter run --flavor staging`

## Production (`prod`)
- Package ID: `com.fishauctions.app`
- API: `https://api.fishauctions.com`
- Logging: Error only
- Build: `flutter run --flavor prod`

## Building APKs/AABs for Release

### Development APK
```bash
flutter build apk --flavor dev --release
```

### Staging AAB
```bash
flutter build appbundle --flavor staging --release
```

### Production AAB
```bash
flutter build appbundle --flavor prod --release
```

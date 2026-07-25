# fishauctions-app

The source code for the mobile app of [auction.fish](https://auction.fish).

The app loads the auction.fish website and extends it with the things that
aren't possible on the web:

- **Square Tap to Pay** — take card payments on the phone itself, no reader
- **Augmented reality lot mode** — point the camera at a table of lots and see
  what they are, or get directed to the one you're looking for
- **Bluetooth label printing** — print lot labels on a thermal label printer
- **Push notifications**
- **Offline auction management** — keep an in-person auction running with no
  connection, and sync it up afterwards

The site itself is a Django project at
[iragm/fishauctions](https://github.com/iragm/fishauctions); everything that
isn't hardware lives there, not here.

## Building it

The Flutter app is in [`fishauctions_application/`](fishauctions_application/).

```bash
cd fishauctions_application
flutter pub get
flutter run --flavor dev -t lib/main.dart --dart-define=FLAVOR=dev
```

- [`DEVELOPMENT.md`](fishauctions_application/DEVELOPMENT.md) — project layout,
  commands, CI gates
- [`BUILD_VARIANTS.md`](fishauctions_application/BUILD_VARIANTS.md) — the dev /
  staging / prod flavors and release builds
- [`CLAUDE.md`](fishauctions_application/CLAUDE.md) — architecture and the
  `/api/mobile/` contract each feature above talks to
- [`IOS.md`](fishauctions_application/IOS.md),
  [`PUSH.md`](fishauctions_application/PUSH.md),
  [`GOOGLE_SIGNIN.md`](fishauctions_application/GOOGLE_SIGNIN.md) — setup that
  needs accounts, certificates, or a Mac

Licensed under the GPL v3 ([`LICENSE`](LICENSE)).

import 'package:geolocator/geolocator.dart';

/// Reads the device position so the WebView can hand it to the Django backend.
///
/// The web UI normally gets coordinates from the browser's geolocation prompt
/// and writes them to `latitude`/`longitude` cookies; the server reads those
/// per request to show auction/lot distances. In the app there is no browser
/// prompt, so we acquire the position natively and the WebView writes the same
/// cookies (see `WebViewScreen`).
///
/// Everything here is best-effort: if permission is denied or the location
/// service is off we return null and set no cookies, so the user simply sees
/// listings without distances — exactly what a web visitor who declines the
/// prompt sees.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  /// Whether the app already holds whileInUse (or always) permission.
  /// Never prompts.
  Future<bool> hasPermission() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Whether [requestAndGetPosition] can still surface an OS dialog — i.e. the
  /// user hasn't permanently denied location. Lets callers avoid offering an
  /// "Enable location" affordance that would be a dead-end (the only fix is the
  /// system Settings app). Never prompts.
  Future<bool> canPrompt() async =>
      await Geolocator.checkPermission() != LocationPermission.deniedForever;

  /// Reads the position **without** prompting — returns null unless permission
  /// is already granted.
  ///
  /// [fresh] `false` returns the cached last-known fix instantly (never waits
  /// on GPS) — use it before a navigation so a returning user gets distances
  /// without delay. [fresh] `true` requests a current fix (falling back to the
  /// last-known one) — use it on app foreground, where a short wait is
  /// invisible.
  Future<Position?> positionIfPermitted({bool fresh = true}) async {
    if (!await hasPermission()) {
      return null;
    }
    return fresh ? _read() : Geolocator.getLastKnownPosition();
  }

  /// Prompts for whileInUse permission if the user hasn't decided yet, then
  /// returns the position. Returns null when denied, permanently denied, or the
  /// location service is off. Safe to call when already granted (no second
  /// prompt).
  ///
  /// Call this from a location-aware screen once it has rendered — not at cold
  /// start — so the OS dialog appears in context.
  Future<Position?> requestAndGetPosition() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      return null;
    }
    return _read();
  }

  /// A fix good enough to *write down* as a place, for the admin "set this
  /// auction's location from my phone" flow. Null when one can't be had.
  ///
  /// Everything else here reads a position to answer "roughly how far away is
  /// this?", where [LocationAccuracy.medium] and a stale cached fallback are
  /// the right trade. Pinning an auction is the opposite problem: the value is
  /// stored permanently, and from then on it *is* the geofence every attendee
  /// is measured against — a 500 ft welcome radius centered on a fix that was
  /// itself 100+ m out, or was taken at the last place the phone happened to
  /// look, is worse than the geocoded street address it replaced. So this asks
  /// for the best fix the hardware has, waits longer for it, and then checks
  /// what it got: an [accuracyFloorMetres] radius of error or a fix older than
  /// [maxFixAge] is refused rather than silently pinned.
  ///
  /// This is also the one place the coarse-location loophole matters. Android's
  /// "Approximate" grant and iOS's "Precise Location: off" both leave
  /// [hasPermission] true while handing back a fix good to a city block or
  /// worse; the accuracy check is what notices, and the caller turns it into
  /// "couldn't get an accurate position" instead of a wrong pin nobody can see
  /// is wrong.
  Future<Position?> precisePosition({
    double accuracyFloorMetres = 50,
    Duration maxFixAge = const Duration(minutes: 2),
  }) async {
    if (!await hasPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      return null;
    }
    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        // LocationSettings already defaults to LocationAccuracy.best; the
        // long time limit is the deliberate part — a cold GPS fix at a venue
        // takes far longer than the 10 s a distance figure is allowed.
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 30),
        ),
      );
    } on Object {
      // Deliberately no last-known fallback: the whole point is that this
      // reading describes where the phone is *now*.
      return null;
    }
    if (position.accuracy > accuracyFloorMetres) {
      return null;
    }
    if (DateTime.now().difference(position.timestamp) > maxFixAge) {
      return null;
    }
    return position;
  }

  Future<Position?> _read() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return null;
    }
    try {
      // Medium accuracy is plenty for a distance-to-auction figure and is
      // faster / lower power than a precise GPS fix. Time-box it so a cold GPS
      // start can't hang the WebView load.
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } on Object {
      // Timeout or a transient platform error — fall back to the last known
      // fix so a brief hiccup still yields usable coordinates (may be null).
      return Geolocator.getLastKnownPosition();
    }
  }

  /// Whether [path] is a web screen that shows distances and therefore warrants
  /// offering location. Only the auctions and lots screens qualify (their list
  /// and detail pages, e.g. /lots/all/ or /lots/123/) — the home page and
  /// everything else must not trigger a prompt at app open.
  static bool isLocationAwarePath(String path) =>
      path.startsWith('/auctions') || path.startsWith('/lots');

  /// Formats a coordinate the way the web writes it to `document.cookie`: a
  /// plain decimal string the server can `float()` directly — no quoting, no
  /// JSON. Mirrors JavaScript's `Number.toString()` for realistic lat/long
  /// magnitudes.
  static String formatCoordinate(double value) => value.toString();
}

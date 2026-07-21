# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

Parts 1–4 (printing, push, AR v1, offline sync) are implemented on the backend
and were removed from this file; see git history if needed. Numbering continues
from there.

---

# Part 5 — AR: per-frame GPS anchoring (done) & absolute heading (future)

Both ride the observation payload the app already sends
(`POST /api/mobile/ar/observations/`) — extra optional fields per frame,
alongside `yaw_deg`, so older app/backend builds keep working. One value per
frame (reuse the freshest reading between updates).

## 5.1 GPS latitude/longitude — implemented (app + backend)

Each frame may carry the phone's fix at capture:

```jsonc
"frames": [
  {
    "frame_id": "f001",
    "captured_at": "2026-07-20T18:31:04.512Z",
    "yaw_deg": -93.46,
    "latitude": 40.44182,     // WGS84 degrees, phone GPS fix at capture
    "longitude": -79.99591,
    "detections": [ /* … */ ]
  }
]
```

App rules (all live in the client now):

* **Send both or neither.** Omitted/null whenever there's no fix — no location
  permission, no lock, or a stale read. The app never sends `(0, 0)` as "no
  fix"; the server also treats a half-supplied, out-of-range, or `(0,0)` fix as
  null, but the intent is null from the app.
* **Coarse is fine.** GPS only positions whole disconnected islands relative to
  each other (island base = GPS centroid in a local east/north metre frame),
  never an individual lot, so indoor accuracy is plenty. The app grabs the
  last-known fix (`getLastKnownPosition`) and never blocks scanning for a lock.
* **Per frame, not per session** — a session that walks between rooms anchors
  each area correctly.

Backend: `ArFrameSerializer` accepts the pair, `validate()` nulls a bad/half/
`(0,0)` fix instead of 400-ing the batch, `ingest_observations` stamps it on
every detection row, and `_gps_cold_bases` places each island at its GPS
centroid. **This is done** — the section stays here only as the app-side
contract of record.

## 5.2 Absolute compass heading — app sends it now, backend TODO

GPS gives an island's *position* but not its *orientation* (a fix has no
heading), so a disconnected island can be dropped in the right place but rotated
arbitrarily. To also fix orientation the app now sends an absolute compass
heading per frame:

```jsonc
{
  "frame_id": "f001",
  // …
  "heading_deg": 137.4    // camera azimuth, degrees CW from MAGNETIC north
}
```

* **Convention:** degrees clockwise from **magnetic** north (0 = N, 90 = E),
  tilt-compensated (magnetometer + gravity), for the camera's forward (−z)
  axis. Absent/null when the device has no magnetometer reading — treat as
  "unknown", never 0.
* **Magnetic, not true.** The backend can convert to true heading with a
  declination model from the frame's own `latitude`/`longitude` + date; the app
  deliberately doesn't (it would need to bundle a WMM table). Even uncorrected,
  it's an absolute reference shared across sessions, which is what island
  orientation needs.
* **Relationship to `yaw_deg`:** `yaw_deg` is *relative* (integrated gyro,
  arbitrary zero per session) and already used for within-/between-frame
  chaining. `heading_deg` is *absolute*; pairing the two lets the solver rotate
  each island into a common north-referenced frame.

Backend work (not yet done): consume `heading_deg` to constrain each island's
rotation (magnetic→true via declination from the fix), weighting it loosely —
indoor magnetic interference is real, so treat it as a soft prior, not a hard
constraint. Until then the field is ignored harmlessly, exactly as `yaw_deg`
was before AR v2 landed.
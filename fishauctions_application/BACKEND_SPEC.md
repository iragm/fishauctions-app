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

# Part 5 — AR v2: gyro heading chaining & island handling

## Why (what v1 cannot do)

Two gaps in the shipped AR solver (`auctions/ar_mapping.py`), confirmed by
review:

1. **Lots a table apart never get correct relative positions.** The solver
   gives every `(session_id, frame_id)` a free heading θ. Frames with ≥2
   detections constrain lots against each other through bearing differences —
   but a QR label is only decodable from a couple of meters, so two lots on
   different tables are essentially never co-visible in one frame. A
   single-detection frame's bearing is absorbed entirely by its free θ; all
   that remains is the weak depression pseudo-range plus the ≤3 m/10 s motion
   chain. Net effect: the *direction* from table A to table B is decided by
   the initializer's assume-no-rotation guess (`_initial_guess` reuses
   `last_theta`) held in place by the 0.01-weight camera tether — i.e. it is
   arbitrary. Walks longer than `MOTION_WINDOW_S` (10 s) between labels sever
   the chain entirely.
2. **Islands overlap on the map and never knowably merge.** Connectivity is
   not modeled: disconnected clusters ("islands") are solved in one problem,
   each new session's first unanchored frame initializes at the origin
   (`_initial_guess` → `(0, 0)`), so unrelated islands render interleaved on
   the admin map and `positions/` can't tell the app that two coordinates are
   in unrelated frames. Locate mode could aim a confident arrow at a target
   whose coordinates come from a different island.

The fix: the app now reports the phone's **rotation** between frames (it was
already integrating gyro yaw for locate mode), and the solver uses it as
heading odometry; components get detected, labeled, gauged and published.

**App status: shipped** (this repo). Each uploaded frame now carries
`yaw_deg`; the app also already parses `component` on `positions/` rows and
refuses cross-component fixes/ghost-anchors. Old app versions simply omit
`yaw_deg` — the solver must keep working (v1 behavior) for yaw-less sessions.

## 5.1 Wire + model changes

`POST /api/mobile/ar/observations/` — frame objects gain one optional field:

```json
{ "frame_id": "f000012", "captured_at": "...", "yaw_deg": -93.46,
  "detections": [ ... ] }
```

- `yaw_deg`: the phone's integrated gyro heading at capture, **degrees,
  ccw-positive about gravity, zero at session start** (math convention seen
  from above — the same sign as the solver's θ, *not* the +right convention
  of `bearing_deg`). Cumulative and unwrapped: three left turns read +1080.
  Absent ⇒ the device gave no gyro data; **absence means "unknown", never
  "didn't turn"**.
- `ArFrameSerializer`: `yaw_deg = serializers.FloatField(required=False,
  allow_null=True)`; drop values with `abs() > 36000` (junk guard).
- `LotObservation.yaw_deg = models.FloatField(null=True, blank=True)` +
  migration; passthrough in `ar_service.ingest_observations` (every detection
  row of a frame stores the frame's yaw, same as `frame_id` today).

## 5.2 Solver: heading odometry (`ar_mapping.py`)

Between consecutive frames `a → b` of one session where **both** carry yaw,
add a residual tying their θs to the measured turn:

```
wrap((θ_b − θ_a) − radians(yaw_b − yaw_a)) / σ_gyro(Δt)
σ_gyro(Δt) = 0.01 + 0.001·Δt_seconds     # rad; drift grows with the gap
```

- Apply for **any Δt within the session** (yaw is cumulative, so the link
  survives a 2-minute walk between tables), capped at ~10 min pairs.
- Keep the translation prior, but scale its cap with walking pace instead of
  the flat 3 m: `cap = max(3.0, 1.5·Δt_seconds)` m, window widened from 10 s
  to ~60 s (beyond that translation is genuinely unknown; the heading link
  above still applies).
- `_initial_guess`: when frames carry yaw, seed each frame's θ from
  `θ_anchor + Δyaw` instead of `last_theta`, and keep rigid-alignment for
  position. This removes the assume-no-rotation guess that currently decides
  cross-table directions.
- Sparsity: each new residual touches only `θ_a, θ_b` — two entries per row.

Effect: a user walking table A → table B scanning one label at a time now
produces real geometry — bearings become rays in a session-rigid frame
(rotation known from gyro), depression gives ranges, the translation prior
bounds the walk — so A-to-B direction is *measured*, and one scanning walk
connects two islands with correct relative orientation.

## 5.3 Components (islands): detect, gauge, label, merge

Build a union-find over the factor graph each solve: nodes are frames and
landmarks; edges are observations (frame↔lot) plus session chain links
(frame↔frame heading/motion pairs). Each resulting component is an island.

- **Anchoring:** a component containing **≥2 lots** with stored
  `LotPosition` priors keeps those priors (it is rigidly tied to the existing
  map frame; one lot is not enough — rotation about a single point stays
  free, same reason locate-mode resection needs 3 and `_rigid_align` needs 2).
  A component with <2 prior lots gets its own cold-start gauge (first
  landmark pinned, second on +x) **at an offset origin** so islands never
  render overlapping: place component k's origin beyond the union bounding
  box of already-placed components (e.g. `(max_x + 20 m, 0)`).
- **Labeling:** `LotPosition.component = models.IntegerField(default=0)`.
  Ids persist across solves: a component inherits the smallest stored id
  among its prior lots; a fresh island takes `max(existing) + 1`. When a
  scanning walk links two stored components, union-find joins them, the solve
  lays them out in one frame, and every row is rewritten with the surviving
  (smaller) id — that's the "eventually one interconnected network" path, and
  it needs nothing from users beyond someone scanning a few labels while
  walking between the areas.
- **Publish:** `GET ar/positions/` rows gain `"component": <int>`. The app
  (already shipped) treats rows in a different component than the target as
  unmapped: no wrong-frame fixes, no wrong-frame ghost anchors — the user is
  told to scan labels near the target instead of being pointed somewhere
  confident and wrong. The admin map should render components as visually
  separate clusters (the origin offset above does this for free) and may
  badge them ("2 unconnected areas — walk between them while scanning to
  join the map").

## 5.4 Persistence: stop deleting positions with their observations

Today `update_positions_for_auction` deletes `LotPosition` rows whose lot has
no surviving observation, and the recency weight floor
(`MIN_WEIGHT`/`HALF_LIFE_HOURS`) drops observations after ~9 h — so the map
dissolves overnight and a Friday-scanned island is gone by Saturday, which
directly fights "eventually interconnected".

Change: **keep** stale `LotPosition` rows (skip, don't delete, lots absent
from the new solve). They remain the best guess, they keep serving as merge
anchors/priors for later sessions, and "recent scans win" is unaffected —
fresh observations always dominate the 0.1-weight priors, so a moved lot
snaps to its new spot on the next scan. Delete rows only on: admin "clear all
locations", lot removed/deleted, or the existing sold-lot exclusion. Surface
staleness instead of deleting: the payload/admin map already have
`updated_at`; decay *displayed* confidence by age.

Keep the 24 h `LotObservation` prune unchanged.

## 5.5 Tests to ship

- Serializer: `yaw_deg` optional, null-tolerated, junk-clamped, persisted.
- Solver, heading chaining: synthetic session walking two clusters ~6 m
  apart, one detection per frame, yaw consistent with the walk → relative
  direction between clusters recovered within a few degrees (this exact case
  is unconstrained in v1 — assert it *fails* without yaw to pin the value of
  the feature).
- Solver, drift: same scenario with ±2°/min yaw drift still converges.
- Yaw-less sessions (old app): v1 behavior preserved, no crash, no regression
  in the existing solver tests.
- Components: two disjoint clusters → distinct `component` ids, disjoint
  bounding boxes; a linking walk merges them into one id and one frame.
- Persistence: positions survive observation expiry; cleared by the admin
  button; moved lot relocates after fresh scans despite its stale prior.

---

# Part 6 — Proximity check-in & join ("welcome to the auction")

## Product requirements (recap)

- A user physically arriving at an **in-person, single-location** auction —
  within **500 ft** of its pickup location, from **3 h before the start**
  until the auction has pretty much ended — gets a welcome nudge:
  - **Not joined yet:** "Welcome to the ⟨auction⟩." with **Join** / **Read
    rules**. Join joins immediately (no scrolling to the bottom of the rules)
    and lands them on the rules page afterwards.
  - **Already joined or added by email**, auction uses **check-in mode**
    (`Auction.use_check_in_mode`), not yet checked in: check them in
    automatically and confirm — "Welcome to ⟨auction⟩ — you're all checked
    in!"
- New auction field **`exact_location_set`**, copied by the
  copy-to-new-auction flow like the other cloned fields.
- **Location correction loop:** within the same 3 h-before window, an auction
  **admin** whose phone is within **2 miles** of the auction's location while
  `exact_location_set` is false gets "Set location for ⟨auction⟩" — accepting
  writes the phone's current position as the auction's location and sets
  `exact_location_set`. (2 mi, not 500 ft: the whole point is the stored
  location may be wrong or vague, so the admin geofence must be generous.)
- Every one of these mutations lands in the auction history.

## How it's delivered (decided app-side, already shipped in the app)

**Foreground position pings, server decides everything.** The app does not
run a background geofence (that needs `ACCESS_BACKGROUND_LOCATION`, a Play
review burden, and violates the app's never-prompt-for-location-unprompted
rule). Instead, while the WebView shell is up the app POSTs its position to
`checkin/ping/` at mount, on app-resume, and every 10 min — **only when
location permission was already granted** contextually elsewhere. The server
evaluates geofence + window + join/check-in/admin state, performs the
auto-check-in itself, and returns display-ready actions; the app renders them
(bottom sheet for the join offer, snackbar for the check-in confirmation,
dialog for the admin location offer). All copy comes from the server. People
arriving at an auction open the app anyway, so foreground-only covers the
real flow; if FCM push later goes live these nudges can *also* be pushed, but
the trigger still requires a position report, so the ping stays the source of
truth.

App degradation: a 404 from `checkin/ping/` disables pings for the process —
deployments without Part 6 see zero behavior change.

## 6.1 Model changes

```python
# Auction
exact_location_set = models.BooleanField(default=False)
exact_location_set.help_text = "The location was pinned from a phone at the venue (or confirmed exact)."
```

- Add to the fields the copy-to-new-auction flow carries over (same list as
  the other cloned rule fields, `views.py` auction-clone path ~8458).
- The auction's "location" here means its **single pickup location** row
  (`auction.location_qs` excluding `pickup_by_mail`; the feature only applies
  when exactly one exists).

```python
class CheckinNudge(models.Model):
    """One-shot bookkeeping: which proximity nudge was already issued to whom.

    Ensures a user who dismisses the sheet isn't re-nudged on every ping;
    unique per (user, auction, kind)."""
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    auction = models.ForeignKey(Auction, on_delete=models.CASCADE)
    kind = models.CharField(max_length=20)  # join_offer | checked_in | set_location_offer
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "auction", "kind"], name="one_nudge_per_kind")]
```

The `checked_in` kind exists only as a sanity cap — the auto-check-in itself
is naturally idempotent (`AuctionTOS.checked_in` is a timestamp).

## 6.2 `POST /api/mobile/checkin/ping/`

`IsMobileAuthenticated`; throttle: a new scope `"mobile_checkin": "30/hour"`
(the app pings every 10 min plus resumes).

```json
Body:    { "latitude": 44.47, "longitude": -73.21 }
Returns: { "actions": [
  { "type": "join_offer", "auction": "<slug>", "title": "<Auction title>",
    "message": "Welcome to the <Auction title>.",
    "rules_url": "/auctions/<slug>/" },
  { "type": "checked_in", "auction": "<slug>", "title": "...",
    "message": "Welcome to <Auction title> — you're all checked in!" },
  { "type": "set_location_offer", "auction": "<slug>", "title": "...",
    "message": "Use this phone's current position as the auction's location." }
] }
```

Evaluation, per candidate auction (usually 0 or 1):

- **Candidates:** `is_online=False`, exactly one non-mail pickup location,
  and inside the welcome window: `date_start − 3 h ≤ now` and the auction has
  not "pretty much ended" — reuse the existing ended semantics (the same
  property the in-person UI uses to stop treating the auction as live, e.g.
  `date_end`/dynamic end when set, else `date_start + 12 h` as the fallback);
  the intent is *stop welcoming people once it's wrapped up*, exact knob is
  the implementer's choice.
- **Distance:** `distance_to(lat, lon)` annotation on the pickup location
  (`models.py:261`, miles). Welcome radius 500 ft ≈ **0.095 mi**; admin
  radius **2 mi**.
- **Join state:** an `AuctionTOS` for this auction matching
  `user=request.user` **or** `email__iexact=request.user.email` (the
  added-by-email case). If an email-matched row has `user=None`, bind it to
  this user now (that's the same claim the web flow does).
- Then, in priority order per auction:
  1. No TOS row and within 500 ft → **`join_offer`** (record nudge, once per
     user+auction).
  2. TOS row exists, `auction.use_check_in_mode`, `checked_in is None`,
     within 500 ft → set `checked_in = now`, write auction history, return
     **`checked_in`** (no nudge row needed beyond the sanity cap).
  3. `request.user` is an auction admin (creator or `AuctionTOS.is_admin`,
     the same check `views.py is_auction_admin` performs),
     `exact_location_set` is False, within 2 mi → **`set_location_offer`**
     (record nudge). This can coexist with 1/2 in one response.

Junk coordinates (|lat| > 90 etc.) → 400. Never 404s for "no auction nearby"
— that would trip the app's endpoint-missing degradation; return
`{"actions": []}`.

## 6.3 `POST /api/mobile/checkin/join/`

```json
Body:    { "auction": "<slug>" }
Returns: { "joined": true, "checked_in": true|false,
           "rules_url": "/auctions/<slug>/" }
```

- Creates the `AuctionTOS` through the same path the web rules-page confirm
  uses (so counters, defaults — pickup location assignment for the single
  location — and any duplicate handling behave identically). Idempotent: an
  existing row returns `joined: true` unchanged.
- When `use_check_in_mode`: also set `checked_in = now` — the user is
  physically at the venue; joining and standing in line to check in twice
  would be silly.
- No distance re-check (the offer already required it; phones drift).
  Auction must still be inside the welcome window.
- Auction history: "⟨user⟩ joined via the app's welcome prompt".

## 6.4 `POST /api/mobile/checkin/set-location/`

```json
Body:    { "auction": "<slug>", "latitude": ..., "longitude": ... }
Returns: { "set": true }
```

- Admin-only (same check as above); 403 otherwise.
- Writes `latitude`/`longitude` (and `location_coordinates`) on the
  auction's single pickup location, sets `exact_location_set = True`.
- Auction history: "Exact location set from ⟨user⟩'s phone position".

## 6.5 Auction history

All three mutations use the existing history plumbing
(`create_history`/`AuctionHistory`, `models.py` ~4759/~10678): proximity
check-in, join-via-welcome, exact-location-set.

## 6.6 Tests to ship

- Geofence: inside/outside 500 ft; admin inside/outside 2 mi; multi-location
  and online auctions never match; window edges (3 h before start; after
  ended).
- Join-state branches: no TOS → join_offer; TOS by email with null user →
  bound + checked in; checkin-mode auto-check-in idempotent and
  history-logged; non-checkin auctions get no `checked_in` action.
- Nudge dedupe: second ping returns no repeat `join_offer`.
- `join/`: creates TOS once, checks in on checkin-mode auctions, history
  entry, works when added-by-email row exists.
- `set-location/`: admin-gated, writes coords + flag + history; refused when
  `exact_location_set` already true.
- Clone flow copies `exact_location_set`.

---

# Part 7 — Recruit volunteers ("ask for help")

Almost entirely a web feature (per the backend-first principle); the app's
only involvement is that job announcements ride the Part 2 push pipeline once
FCM is live, and the accept flow is a plain web page in the WebView. **No app
release is needed for any of this part.**

## Product requirements (recap)

- In-person auctions get **More → Recruit volunteers** in the auction admin
  ribbon (`auction_ribbon.html` "More" dropdown, admin-gated like "Set lot
  winners").
- The page explains: "Use this page to get help from users in your auction.
  This will send a notification to people with the mobile app who can
  volunteer to help with the job you specify." — with a tooltip showing the
  **count of reachable helpers**: distinct users holding a registered
  `MobileDevice` who are *checked in* when `use_check_in_mode`, otherwise
  *joined* (`AuctionTOS`).
- Form: **Job** (placeholder "What do you need help with?"), **Bounty**
  (help text: "Leave blank for volunteer. Add an invoice adjustment to pay
  people for signing up for this job"), **How many people do you need?**
  (default 1, help text "Jobs are first come, first serve").
- Below the form: past jobs in this auction with requested/volunteered
  counts.
- Submitting notifies eligible app users with the job description; tapping
  opens the job's accept page. Accepting while spots remain records the
  signup, applies the bounty as an invoice discount, and confirms; when the
  job is already full the user gets told so. A filled job's notification is
  withdrawn.
- Everything lands in auction history.

## 7.1 Models

```python
class VolunteerJob(models.Model):
    auction = models.ForeignKey(Auction, on_delete=models.CASCADE, related_name="volunteer_jobs")
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, on_delete=models.SET_NULL)
    description = models.CharField(max_length=200)          # "Job" on the form
    bounty = models.DecimalField(max_digits=6, decimal_places=2, null=True, blank=True)
    people_needed = models.PositiveIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    canceled = models.BooleanField(default=False)

    @property
    def signups_count(self): ...
    @property
    def is_full(self): return self.signups_count >= self.people_needed


class VolunteerSignup(models.Model):
    job = models.ForeignKey(VolunteerJob, on_delete=models.CASCADE, related_name="signups")
    auctiontos = models.ForeignKey(AuctionTOS, on_delete=models.CASCADE)
    created_at = models.DateTimeField(auto_now_add=True)
    invoice_adjustment = models.ForeignKey(InvoiceAdjustment, null=True, blank=True, on_delete=models.SET_NULL)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["job", "auctiontos"], name="one_signup_per_job")]
```

Signups hang off `AuctionTOS` (not `User`) because the bounty is an invoice
adjustment and invoices key off the in-auction identity.

## 7.2 Pages (web, admin ribbon)

- **`/auctions/<slug>/volunteers/`** (admin-gated, in-person only): the
  explainer + helper-count tooltip, the form, and the job list (description,
  needed vs signed up, bounty, created, per-job cancel). Submitting creates
  the `VolunteerJob`, writes history, and fans out the notification (7.4).
- **`/auctions/<slug>/volunteers/<job_pk>/`** (any joined user): the accept
  page the notification opens. Shows description + bounty + spots left and a
  **Sign up** button:
  - User has no `AuctionTOS` → prompt to join first (link to rules page).
  - Spots remain → create `VolunteerSignup`; when `bounty` is set, create an
    `InvoiceAdjustment` (`adjustment_type="DISCOUNT"`, `amount=bounty`,
    `notes="Volunteer: <description>"`) on the user's open invoice for this
    auction (create the invoice if none exists yet, same as other adjustment
    flows), link it on the signup, confirm: "You're signed up!". If the
    signup **fills** the job, withdraw the notification (7.4).
  - Already full → "This job already has enough people." (Also the answer
    for anyone tapping a stale notification — the page, not the push, is the
    source of truth.)
  - Signing up twice is a no-op with a friendly message (unique constraint).

## 7.3 Helper count

```python
AuctionTOS.objects.filter(auction=auction, user__isnull=False,
                          **({"checked_in__isnull": False} if auction.use_check_in_mode else {}))
    .filter(user__mobiledevice__isnull=False).distinct().count()
```

Shown in the tooltip ("N people can be notified right now").

## 7.4 Notifications

Fan out through the Part 2 choke point (`auctions/notifications.py
notify_user` → `send_push_to_user`) to every user in the helper count —
title "⟨Auction title⟩ needs help", body = job description (+ "$X bounty"
when set), data route = the job accept page. While FCM is inert (no
`FIREBASE_CREDENTIALS_JSON` / no tokens) this degrades to the existing email
fallback exactly like every other notification — acceptable, and it lights
up automatically when push goes live.

**Withdrawing on full:** send the push with a per-job `collapse`/`tag` id
and, when the job fills (or is canceled), send a data-only "retract" message
for that tag; the app-side handler (future FCM work, noted in `PUSH.md`)
cancels the displayed notification. Until that app handler exists the safety
net is 7.2: a stale tap lands on the accept page, which says the job is
full. Do **not** block on retraction being perfect — first-come-first-serve
is enforced server-side at signup time, never by the notification.

## 7.5 Auction history

History entries via the existing plumbing for: job created ("asked for N
people: ⟨description⟩ (bounty $X)"), each signup ("⟨tos⟩ signed up for
⟨description⟩"), job filled, job canceled.

## 7.6 Tests to ship

- Page gating: admin-only form; in-person only; menu item hidden otherwise.
- Helper count: checkin-mode counts only checked-in app users; non-checkin
  counts joined app users; users without devices excluded.
- Signup: creates adjustment with correct type/amount/notes and links it;
  volunteer (no bounty) creates no adjustment; fill boundary — people_needed
  reached → next signup refused with the friendly message; duplicate signup
  no-op; race: two simultaneous signups for the last spot → exactly one wins
  (wrap in `select_for_update` on the job).
- Notification fan-out called once per eligible user; retract sent on fill.
- History entries for create/signup/fill/cancel.

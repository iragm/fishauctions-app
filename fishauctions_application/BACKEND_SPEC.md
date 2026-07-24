# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## AR Command Palette Entry — Last-Used-Auction Lookup

**Problem:** the app's command palette (CLAUDE.md's "AR Lot Mode" section) should
offer to open AR lot-scanning mode when the user is near their last-used in-person
auction, or whenever they search for "ar" / "lot scanning" / "augmented reality".
AR is a native camera screen, not a URL `GET /api/mobile/command-palette/` can
return, and that endpoint's items are `{type, title, subtitle, url, icon}` only —
no coordinates, no `is_online`/`pretty_much_over` flags — so the app has nothing to
gate the entry on today. `checkin/ping/` is the wrong tool to reuse for this: it's
a ~500 ft welcome geofence with real side effects (auto-check-in, one-shot nudge
rows, `last_auction_used` writes) — not safe to call just to decide whether to show
a search result.

**Endpoint:** `GET /api/mobile/auctions/last-used/` (JWT auth via
`IsMobileAuthenticated`, `throttle_scope = "mobile_api"` — a light, infrequent
lookup the app makes once per palette open, not per keystroke). Read-only, no side
effects, no request body.

**Response — always `200`.** A `404` is reserved for "this backend build predates
the endpoint" (the app's existing degrade-on-404 convention, same as `ar/lots`,
`ar/positions`, `checkin/ping`) — never used for the empty-data case, which is:

```json
{
  "slug": null,
  "title": null,
  "is_online": null,
  "pretty_much_over": null,
  "latitude": null,
  "longitude": null
}
```

...when the user has no `userdata.last_auction_used`, or it points at a
soft-deleted auction (mirrors `MyLastAuctionLots`'s existing "plain when
unset/deleted" fallback — `views.py`, see `test_my_last_auction_plain_when_unset`
/ `test_my_last_auction_plain_when_deleted` in `test_ar.py`). Otherwise:

```json
{
  "slug": "spring-fry-swap-2026",
  "title": "Spring Fry Swap 2026",
  "is_online": false,
  "pretty_much_over": false,
  "latitude": 40.4406,
  "longitude": -79.9959
}
```

Field notes:

- `is_online` / `pretty_much_over` are `Auction.is_online` / `Auction.pretty_much_over`
  verbatim — same semantics `command_palette.py`'s `_last_auction_active` already
  uses to hide stale shortcuts.
- `latitude` / `longitude` are the auction's single physical pickup location —
  reuse `_single_pickup_location()` from `auctions/mobile/services/checkin.py`
  (exactly one non-mail `PickupLocation`) — when it exists and has coordinates
  set; `null` otherwise (ambiguous/no physical location, mail-only, or
  coordinates unset). The app treats a null pair as "can't distance-gate, don't
  show AR" rather than guessing at a location.

**Suggested implementation** (mirrors existing helpers, no new model/migration):

```python
# auctions/mobile/views.py
from .services.checkin import _single_pickup_location

class MobileLastUsedAuctionView(APIView):
    permission_classes = [IsMobileAuthenticated]
    throttle_scope = "mobile_api"

    def get(self, request):
        auction = getattr(request.user.userdata, "last_auction_used", None)
        if auction is None or auction.is_deleted:
            return Response({
                "slug": None, "title": None, "is_online": None,
                "pretty_much_over": None, "latitude": None, "longitude": None,
            })
        location = _single_pickup_location(auction)
        return Response({
            "slug": auction.slug,
            "title": auction.title,
            "is_online": auction.is_online,
            "pretty_much_over": auction.pretty_much_over,
            "latitude": location.latitude if location else None,
            "longitude": location.longitude if location else None,
        })
```

```python
# auctions/mobile/urls.py
path("auctions/last-used/", MobileLastUsedAuctionView.as_view(), name="mobile-last-used-auction"),
```

**App side** (already being built to consume this): the command palette fetches
this once when it opens, computes distance itself from the device's live GPS, and
locally injects a `PaletteItem(type: "ar", ...)` — routed to the native
`/ar/:auctionSlug` screen instead of `navigateToPath` — when `is_online == false`
and `pretty_much_over == false` and (within 10 miles, or the app has no location
permission to check). A search query matching "ar" / "lot scanning" / "augmented
reality" shows it regardless of distance (still gated on in-person + not
pretty-much-over). No further backend involvement; a `404` here just disables the
entry for the process, same as every other optional mobile endpoint.

---

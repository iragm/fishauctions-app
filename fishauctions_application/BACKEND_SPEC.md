# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part MENU — the app's navigation drawer, served as JSON

**The whole feature is one refactor, and the JSON is the small half.** The
`menu` block below has to be *rendered from the same structure that renders
`base.html`'s navbar* — one Python function returning the sections, two
consumers: the template and this endpoint. If it lands as a hand-written list
in `MobileConfigView`, the feature is not merely pointless, it is a net loss:
there would then be **three** copies of the navbar to keep in step (the
template, the JSON, and the app's compiled-in fallback) where there are two
today, and the one that silently rots would be the one nobody is looking at.
Deduplication is the entire justification. If the refactor is the expensive
part, do the refactor and ship the JSON later.

**Why now.** The drawer has been a hand-copied mirror of the navbar's account
dropdown. That navbar changed in fifteen commits in the last twelve months and
the app could only follow it through an app-store release, so it is
permanently behind. It is also lossy in a way no amount of diligence fixes:
the superuser **Admin** menu and the **About site** link have never been in the
app at all, because *who may see them* is a server question and the app has no
business answering it.

`auctions/command_palette.py` is the precedent — it already builds a list of
`{title, url, icon}` dicts for a user and hands the same structure to two
different front ends.

### Shape

A new optional `menu` key on the existing `GET /api/mobile/config/` response,
alongside `voice` and `firebase`:

```json
"menu": {
  "version": 1,
  "sections": [
    {
      "id": "main",
      "items": [
        {"title": "Auctions", "path": "/auctions/", "icon": "bi-hammer"},
        {"title": "Lots",     "path": "/lots/all/", "icon": "bi-grid"}
      ]
    },
    {
      "id": "lots",
      "title": "My lots",
      "items": [
        {"title": "Selling",      "path": "/selling/",      "icon": "bi-cash-coin"},
        {"title": "Watched lots", "path": "/lots/watched/", "icon": "bi-star-fill"},
        {"title": "Bids",         "path": "/bids/",         "icon": "bi-coin"},
        {"title": "Won lots",     "path": "/lots/won/",     "icon": "bi-calendar-check"}
      ]
    },
    {
      "id": "account",
      "title": "Account",
      "items": [
        {"title": "Account information", "path": "/account/",      "icon": "bi-info-circle"},
        {"title": "Invoices",            "path": "/invoices/",     "icon": "bi-bag"},
        {"title": "Messages",            "path": "/messages/",     "icon": "bi-chat"},
        {"title": "Contact info",        "path": "/contact_info/", "icon": "bi-telephone-fill"},
        {"title": "Preferences",         "path": "/preferences/",  "icon": "bi-sliders"},
        {"title": "Label printing",      "path": "/printing/",     "icon": "bi-tag"},
        {"title": "Ignore categories",   "path": "/ignore/",       "icon": "bi-ban"},
        {"title": "Feedback",            "path": "/feedback/",     "icon": "bi-chat-heart"}
      ]
    },
    {
      "id": "admin",
      "title": "Admin",
      "icon": "bi-shield-lock",
      "collapsed": true,
      "items": [
        {"title": "User stats", "path": "/admin_dashboard/",     "icon": "bi-speedometer2"},
        {"title": "Traffic",    "path": "/admin/traffic/?days=30", "icon": "bi-graph-up"}
      ]
    },
    {
      "id": "about",
      "title": "About",
      "icon": "bi-info-circle",
      "collapsed": true,
      "items": [
        {"title": "About site",            "path": "/promo/", "icon": "bi-globe"},
        {"title": "FAQ",                   "path": "/faq/",   "icon": "bi-question-circle"},
        {"title": "Terms and Conditions",  "path": "/tos/",   "icon": "bi-file-text"}
      ]
    }
  ]
}
```

**Section fields.** `id` is the merge anchor (below) and is never shown; the
app knows `main` and `account` and treats every other id as an ordinary
section, so adding one needs no app release. `title` is the group header —
omit or leave empty for the top group. `collapsed: true` renders the group as
an expandable tile with `icon` on it, which is what the navbar's dropdowns
already are and what keeps a twelve-item Admin menu from burying the rest.

**Item fields.** `title` and `path` are required; an item missing either is
dropped. `icon` is a Bootstrap Icons class name written exactly as the
template writes it (`bi-star-fill`) — the app maps it to the nearest Material
icon and falls back to a neutral chevron for a name it doesn't know, so a new
icon never breaks anything and never needs a release either. Send whatever the
navbar sends.

**`path`** may be site-relative or an absolute URL on this deployment's own
host; query strings are preserved (`?days=30` on the admin links is
load-bearing). **An absolute URL on any other host is dropped, not followed** —
these rows load in the app's own WebView chrome, the same rule `terms_url` and
`privacy_policy_url` already live under. If an off-site link ever needs to be
in the drawer, that is a separate field and a separate discussion, not a
different host in `path`.

`version` is advisory; the app ignores it today. Unknown keys on either object
are ignored, so extending this later is free.

### Per-user gating

**This block is per user, and it is the only part of `/api/mobile/config/`
that is.** Build it from the request's user exactly as the template does:

- staff/superuser → include the `admin` section (`request.user.is_superuser`,
  the same condition `base.html` uses today);
- `enable_promo_page` off → no "About site" row;
- signed out → the signed-out navbar, i.e. no account sections. (The app never
  renders a drawer while signed out, so anything is acceptable here; sending
  only the public sections is the honest answer.)

Two consequences for the view, both small and both easy to miss:

1. **`MobileConfigView` is `authentication_classes = []` today.** It must
   accept the app's JWT *optionally* — authenticate when a bearer token is
   present, stay `permission_classes = []` so an anonymous fetch still
   succeeds. The app already sends `Authorization` on every request including
   this one; today the view simply ignores it.
2. **If this response is ever cached, it must vary per user.** It is
   uncached now, which is fine — do not add a blanket `cache_page` to an
   endpoint that has become user-specific.

The app handles the ordering hazard on its side: the login screen warms this
endpoint before there is a session, so a fresh sign-in re-fetches rather than
keeping the anonymous menu (`ConfigService.loadForCurrentUser`), and sign-out
deletes the stored copy.

### What the server must *not* send

Four rows in the drawer are the app's and cannot be a URL: **Sign out** (it
clears the JWT pair, the WebView cookie jar, the cached profile, the offline
files and the Square authorization — a web `/logout/` link only does one of
those), **Offline mode** and **Tap to Pay** (native screens, each with its own
gating), and **Clubs** (already server-driven, through `clubs/mine/`). Do not put
them in `menu`; the app merges them in itself, at the end of the `main` section
(offline mode, clubs) and the `account` section (Tap to Pay), with sign out
always last. A row whose anchor section is absent is appended near the bottom
rather than lost, so renaming a section id degrades the layout and never the
function.

### How the app behaves, so you know what a mistake costs

Three tiers: **server payload > last good payload persisted on this device >
a deliberately tiny bundled skeleton** (Auctions, Lots, Selling, Watched lots,
Account information, Invoices). The middle tier is why a bad deploy is cheap:
a payload the app can't read is *ignored*, the previous one keeps rendering,
and the file on disk is left alone — so a broken menu degrades to yesterday's
working menu, and the fix is a Django edit with no app release. Individual bad
rows are dropped individually; a section left with no rows is dropped with
them; nothing here can produce an empty drawer.

### Tests worth having on the backend side

The one that matters is that the navbar template and this endpoint come from
the same source: a test asserting that every account-dropdown link rendered
into `base.html` for a given user appears in that user's `menu` payload will
fail the day someone adds a link to only one of them, which is the failure
mode this whole part exists to prevent. Plus the cheap ones: staff gets the
`admin` section and a normal user does not, and every `path` is site-relative.

# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---


## Notes on this document

Earlier parts (printing profiles, push pipeline, AR mapping v1, offline sync,
proximity check-in, the last-used-auction lookup) were removed once the backend
implemented them — `git log` on this file has the history. Several `CLAUDE.md`
references to "Part 1 / Part 6 / Part T / Part W" point at that removed content;
the code and `auctions/mobile/urls.py` are the truth.

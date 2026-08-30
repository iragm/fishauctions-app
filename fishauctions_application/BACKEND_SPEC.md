# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part SUPPORT — a support page that works signed out

**Why:** App Store Connect requires a **Support URL**, and App Review opens it in
a plain browser with no session. The only candidate today is `/faq/`, and
`faq.html` ends with:

```django
Still got questions? Email me:
{% if request.user.is_authenticated %}{{admin_email|urlize}}{% else %}(Sign in to see email){% endif %}
```

So a signed-out reviewer gets substantive FAQ content and then, exactly where the
contact method should be, the words *"(Sign in to see email)"*. That is the shape
of a Guideline 1.5 metadata rejection ("your Support URL does not provide
adequate support information"), and a metadata rejection costs a review round
trip — days — for something worth about twenty minutes.

The address is hidden from anonymous users to keep it off scrapers, which is a
real concern and should stay solved. So: keep hiding the address, add a way to
reach a human that doesn't need an account.

**Smallest fix that satisfies it.** In `faq.html`, replace the signed-out branch
with a link to a contact form rather than the current dead text:

```django
{% if request.user.is_authenticated %}{{admin_email|urlize}}{% else %}<a href="{% url 'contact' %}">Send a message</a>{% endif %}
```

and add a `/contact/` view: an unauthenticated form (name, email, message) that
emails `admin_email`, protected by the same reCAPTCHA the signup flow already
uses. No address is exposed, and the page stands on its own as the Support URL.

**Alternative, if a form is more than you want to build:** seed a `/support/`
`BlogPost` by migration the way `/privacy/` already is
(`PrivacyPolicyView`) — a short page carrying a support address in plain text
plus a link to `/faq/` — and point the Support URL there instead. Fewer moving
parts; the trade is that the address is public.

**No app change either way.** The Support URL is App Store Connect metadata; the
app never loads it.

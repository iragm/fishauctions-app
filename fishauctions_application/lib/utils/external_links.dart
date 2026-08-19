/// Non-`http(s)` URL schemes a web page is allowed to hand off to the OS.
///
/// The two WebViews both cancel every navigation that isn't `http`/`https` —
/// the right default, since a page (or something injected into one) could
/// otherwise reach `javascript:`, `intent:`, `file:` or a scheme belonging to
/// some other app on the phone. But three of the blocked schemes aren't
/// navigations at all: `mailto:`, `tel:` and `sms:` are requests to hand the
/// user to the mail, phone or messaging app, and a browser has always honoured
/// them. Blocking them made every "Email" button on the site — the auction
/// contact, the club contact, "Email all users", the speaker panel, allauth's
/// own confirm-address page — do nothing at all when tapped, with no error and
/// no way to tell a dead button from a slow one.
///
/// The list is deliberately short and closed. It is not "everything that isn't
/// http": `intent:` and `market:` can launch arbitrary apps with arbitrary
/// extras, and this shell renders user-authored HTML (lot descriptions,
/// reference links).
const Set<String> handoffSchemes = {'mailto', 'tel', 'sms'};

/// Whether [uri] is one of the [handoffSchemes] — something to give to the OS
/// rather than to load or to block.
bool isHandoffScheme(Uri uri) =>
    handoffSchemes.contains(uri.scheme.toLowerCase());

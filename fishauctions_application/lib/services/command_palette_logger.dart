import 'dart:async';

import 'command_palette_service.dart';

/// The shape of [CommandPaletteService.log] — pulled out so tests can inject a
/// fake without subclassing the singleton service.
typedef PaletteLogFn =
    Future<int?> Function({
      int? id,
      String search,
      String result,
      String resultType,
      String resultUrl,
      int? resultObjectId,
    });

/// Mutable state of one search session. Each write captures the session it
/// belongs to, so a write's server-assigned id lands on the right session even
/// after `reset` has started a new one (the queued writes of the old session
/// must not leak their row id into the new session).
class _Session {
  int? id;
  bool finalized = false;
  bool searched = false;
  String query = '';
  int resultCount = 0;
}

/// Records a single command-palette search session.
///
/// The web client (`command_palette.js`) used to lose searches exactly when a
/// palette did its job and navigated the user away; this mirrors its fix:
///
///  * The query is logged the instant it's typed ([recordPending]) — *before*
///    results load — so a search survives the user leaving mid-request. A
///    zero-result query is then refined to `bounce` ([recordResults]), the row
///    the analytics page mines hardest.
///  * Every write serializes through one [Future] chain, so the first POST
///    creates the row and assigns the id before any refinement runs. Without
///    this, rapid keystrokes race into duplicate rows because they all read a
///    still-null session id.
///  * [finalize] runs exactly once across all triggers (clear / close / the
///    dispose-time page-hide analog / a result click) and records even when no
///    id has come back yet — the server then creates a fresh row rather than
///    dropping the search.
///
/// In-flight writes are intentionally not awaited at the call sites: the
/// palette navigates within the app (a WebView load), which does not tear down
/// the Dart isolate, so a dispatched POST completes on its own. There is no
/// `keepalive` knob to mirror — the request simply survives the navigation.
class CommandPaletteLogger {
  CommandPaletteLogger({PaletteLogFn? post})
    : _post = post ?? CommandPaletteService.instance.log;

  final PaletteLogFn _post;

  Future<void> _chain = Future<void>.value();
  _Session _session = _Session();

  /// Serializes one write through the chain, threading [session]'s id so later
  /// writes update the same row instead of creating duplicates.
  Future<void> _write(
    _Session session, {
    required String search,
    required String result,
    String resultType = '',
    String resultUrl = '',
    int? resultObjectId,
  }) {
    _chain = _chain.then((_) async {
      final id = await _post(
        id: session.id,
        search: search,
        result: result,
        resultType: resultType,
        resultUrl: resultUrl,
        resultObjectId: resultObjectId,
      );
      if (id != null) {
        session.id = id;
      }
    });
    return _chain;
  }

  /// Logs [query] the moment it's dispatched, before results load.
  void recordPending(String query) {
    final session = _session
      ..searched = true
      ..query = query
      ..resultCount = 0;
    unawaited(_write(session, search: query, result: 'pending'));
  }

  /// Refines the pending row once the result count is known. Only a zero-result
  /// search needs a write (→ `bounce`); a non-empty result stays `pending`
  /// until the user clicks or abandons. Stale results (a newer query has since
  /// been typed) are ignored.
  void recordResults(String query, int count) {
    final session = _session;
    if (query != session.query) {
      return;
    }
    session.resultCount = count;
    if (count == 0) {
      unawaited(_write(session, search: query, result: 'bounce'));
    }
  }

  /// A result click is the terminal outcome — record it and mark finalized so a
  /// later [finalize] trigger doesn't also write an `abandoned`/`bounce` row.
  void recordClick({required String type, required String url, int? objectId}) {
    final session = _session..finalized = true;
    unawaited(
      _write(
        session,
        search: session.query,
        result: 'clicked',
        resultType: type,
        resultUrl: url,
        resultObjectId: objectId,
      ),
    );
  }

  /// Finalizes the search exactly once. A search that produced results and was
  /// walked away from is `abandoned`; anything else (including a search whose
  /// results never arrived) is a `bounce`.
  void finalize() {
    final session = _session;
    if (session.finalized || !session.searched) {
      return;
    }
    session.finalized = true;
    final result = session.resultCount > 0 ? 'abandoned' : 'bounce';
    unawaited(_write(session, search: session.query, result: result));
  }

  /// Finalizes the current session and starts a fresh one, so the next query
  /// gets its own row (used when the user clears the input). The old session's
  /// still-queued writes keep updating the old row, not the new one.
  void reset() {
    finalize();
    _session = _Session();
  }

  /// Resolves once every queued write has flushed. Test-only.
  Future<void> get done => _chain;
}

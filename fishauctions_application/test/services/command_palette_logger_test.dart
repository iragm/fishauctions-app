import 'package:fishauctions_application/services/command_palette_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Captured log writes, in order. Each entry is the arguments of one POST.
  late List<Map<String, Object?>> writes;
  // The id the fake "server" assigns to a freshly-created row.
  const assignedId = 100;

  // A fake CommandPaletteService.log: records the call and, like the server,
  // returns the existing id or assigns a new one on first insert.
  PaletteLogFn recordingPost({int? Function(int? id)? respond}) =>
      ({
        id,
        search = '',
        result = 'pending',
        resultType = '',
        resultUrl = '',
        resultObjectId,
      }) async {
        writes.add({
          'id': id,
          'search': search,
          'result': result,
          'result_type': resultType,
          'result_url': resultUrl,
          'result_object_id': resultObjectId,
        });
        if (respond != null) {
          return respond(id);
        }
        return id ?? assignedId;
      };

  setUp(() => writes = []);

  test('logs pending before results, then refines a zero-result query to '
      'bounce', () async {
    final logger = CommandPaletteLogger(post: recordingPost())
      ..recordPending('zzz')
      ..recordResults('zzz', 0);
    await logger.done;

    expect(writes.map((w) => w['result']), ['pending', 'bounce']);
    expect(writes.every((w) => w['search'] == 'zzz'), isTrue);
  });

  test('serializes writes so the first POST creates the only row and '
      'refinements reuse its id', () async {
    final logger = CommandPaletteLogger(post: recordingPost())
      ..recordPending('gup')
      ..recordResults('gup', 0)
      ..finalize();
    await logger.done;

    // Exactly one create (the lone null-id write); everything else reuses it.
    expect(writes.where((w) => w['id'] == null), hasLength(1));
    expect(writes.first['id'], isNull);
    expect(writes.skip(1).every((w) => w['id'] == assignedId), isTrue);
  });

  test('finalize records the search even before an id comes back', () async {
    // The server contract the client leans on: a finalize with no id still
    // records the search (server creates a fresh row). Here the create POST
    // never resolves an id.
    final logger =
        CommandPaletteLogger(post: recordingPost(respond: (_) => null))
          ..recordPending('gup')
          ..finalize();
    await logger.done;

    expect(writes.last['search'], 'gup');
    expect(writes.last['result'], 'bounce');
    expect(writes.last['id'], isNull);
  });

  test('finalize fires exactly once across repeated triggers', () async {
    final logger = CommandPaletteLogger(post: recordingPost())
      ..recordPending('gup')
      ..recordResults('gup', 3) // had results → abandoned, not bounce
      ..finalize()
      ..finalize()
      ..finalize();
    await logger.done;

    expect(writes.where((w) => w['result'] == 'abandoned'), hasLength(1));
  });

  test('a click finalizes the session so dispose does not also '
      'abandon it', () async {
    final logger = CommandPaletteLogger(post: recordingPost())
      ..recordPending('gup')
      ..recordResults('gup', 5)
      ..recordClick(type: 'lot', url: '/lots/1/', objectId: 1)
      ..finalize(); // dispose-time trigger — must be a no-op now
    await logger.done;

    final click = writes.singleWhere((w) => w['result'] == 'clicked');
    expect(click['result_type'], 'lot');
    expect(click['result_url'], '/lots/1/');
    expect(click['result_object_id'], 1);
    expect(writes.where((w) => w['result'] == 'abandoned'), isEmpty);
  });

  test('finalize does nothing when no search was ever typed', () async {
    final logger = CommandPaletteLogger(post: recordingPost())..finalize();
    await logger.done;

    expect(writes, isEmpty);
  });

  test('stale results from a superseded query are ignored', () async {
    final logger = CommandPaletteLogger(post: recordingPost())
      ..recordPending('gup')
      ..recordPending('guppy')
      ..recordResults('gup', 0); // late results for the old query
    await logger.done;

    // No bounce written for 'gup'; only the two pending rows exist.
    expect(writes.map((w) => w['result']), ['pending', 'pending']);
  });

  test('reset finalizes the current search and the next query starts a fresh '
      'row', () async {
    final logger = CommandPaletteLogger(post: recordingPost())
      ..recordPending('a')
      ..recordResults('a', 0)
      ..reset()
      ..recordPending('b');
    await logger.done;

    final bWrites = writes.where((w) => w['search'] == 'b').toList();
    expect(bWrites, hasLength(1));
    expect(bWrites.first['id'], isNull, reason: 'a new session creates a row');
  });
}

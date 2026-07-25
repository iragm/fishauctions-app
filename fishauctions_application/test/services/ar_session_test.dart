import 'dart:math' as math;

import 'package:fishauctions_application/models/ar_models.dart';
import 'package:fishauctions_application/services/ar_session.dart';
import 'package:fishauctions_application/utils/ar_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed-seed clock the tests advance by hand.
class _Clock {
  DateTime now = DateTime.utc(2026, 7, 17, 12);
  void advance(Duration d) => now = now.add(d);
}

ArMeasurement _m({double bearing = 0, double depression = 20}) =>
    ArMeasurement(bearingDeg: bearing, depressionDeg: depression, quality: 0.8);

void main() {
  late _Clock clock;
  late List<List<ArFrame>> sent;
  late List<List<ArEvent>> sentEvents;
  late ArSessionController session;

  setUp(() {
    clock = _Clock();
    sent = [];
    sentEvents = [];
    session = ArSessionController(
      auctionSlug: 'test-auction',
      sender: (sessionId, frames) async => sent.add(frames),
      eventSender: (events) async => sentEvents.add(events),
      clock: () => clock.now,
      random: math.Random(7),
    );
  });

  group('observation batching', () {
    test('per-lot throttle: a still camera does not spam duplicates', () {
      session.addFrame({1: _m()});
      clock.advance(const Duration(milliseconds: 300));
      session.addFrame({1: _m()});
      expect(session.bufferedFrames, 1);
      // …but after the interval the lot may contribute again.
      clock.advance(ArSessionController.perLotInterval);
      session.addFrame({1: _m()});
      expect(session.bufferedFrames, 2);
    });

    test('a frame keeps only detections that pass the throttle', () {
      session.addFrame({1: _m()});
      clock.advance(const Duration(milliseconds: 300));
      session.addFrame({1: _m(), 2: _m(bearing: 10)});
      expect(session.bufferedFrames, 2);
      // The second frame carried only lot 2.
      clock.advance(ArSessionController.flushInterval);
      session.addFrame({3: _m()});
      expect(sent, hasLength(1));
      expect(sent.first[1].detections.map((d) => d.lotPk), [2]);
    });

    test('flushes on the interval', () {
      session.addFrame({1: _m()});
      expect(sent, isEmpty);
      clock.advance(ArSessionController.flushInterval);
      session.addFrame({2: _m()});
      expect(sent, hasLength(1));
      expect(sent.first, hasLength(2));
    });

    test('flushes when the buffer fills', () {
      for (var i = 0; i < ArSessionController.maxBufferedFrames; i++) {
        // Distinct lots so the throttle never intervenes.
        session.addFrame({100 + i: _m()});
        clock.advance(const Duration(milliseconds: 100));
      }
      expect(sent, hasLength(1));
      expect(sent.first, hasLength(ArSessionController.maxBufferedFrames));
      expect(session.bufferedFrames, 0);
    });

    test('flushIfDue pushes out a trailing batch', () {
      session
        ..addFrame({1: _m()})
        ..flushIfDue();
      expect(sent, isEmpty); // not due yet
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      expect(sent, hasLength(1));
    });

    test('frames record the AR-tracked yaw at capture', () {
      // No pose data yet before the first frame: yaw must be absent, not
      // zero. Then turn left 90° (ccw about gravity) and sight lot 2.
      session
        ..addFrame({1: _m()})
        ..updateOdometryFromPose(yawRad: math.pi / 2, odoX: 0, odoY: 0)
        ..addFrame({2: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frames = sent.single;
      expect(frames.first.yawDeg, isNull);
      expect(frames.last.yawDeg, closeTo(90, 0.01));
    });

    test('stamps frames with the latest absolute heading', () {
      session
        ..updateHeading(123.4)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.headingDeg, 123.4);
    });

    test('odometry is omitted until a tracked pose arrives', () {
      session.addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.odoXM, isNull);
      expect(frame.odoYM, isNull);
    });

    test('a tracked pose reports the session origin as (0, 0), not absent', () {
      session
        ..updateOdometryFromPose(yawRad: 0, odoX: 0, odoY: 0)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.odoXM, 0);
      expect(frame.odoYM, 0);
    });

    test('odometry tracks the AR pose directly, no stride math', () async {
      session
        ..updateOdometryFromPose(yawRad: 0, odoX: 1.5, odoY: 0)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final straight = sent.single.single;
      expect(straight.odoXM, closeTo(1.5, 1e-9));
      expect(straight.odoYM, closeTo(0, 1e-9));

      // Let flush()'s fire-and-forget `finally` (which resets the in-flight
      // guard) settle before triggering a second cycle — it only needs a
      // microtask in real usage because the event loop pumps between the
      // screen's timer ticks, which a synchronous test body doesn't do.
      await Future<void>.value();

      // A later pose update simply replaces the value — the whole point of
      // pose-based odometry is that it's absolute, not accumulated.
      session
        ..updateOdometryFromPose(yawRad: math.pi / 2, odoX: 1.5, odoY: 0.75)
        ..addFrame({2: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final turned = sent[1].single;
      expect(turned.yawDeg, closeTo(90, 1e-6));
      expect(turned.odoXM, closeTo(1.5, 1e-9));
      expect(turned.odoYM, closeTo(0.75, 1e-9));
    });

    test('a null yawRad leaves yaw as-is but still updates odometry', () {
      session
        ..updateOdometryFromPose(yawRad: math.pi / 4, odoX: 0, odoY: 0)
        ..updateOdometryFromPose(yawRad: null, odoX: 2, odoY: 3)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.yawDeg, closeTo(45, 1e-6));
      expect(frame.odoXM, closeTo(2, 1e-9));
      expect(frame.odoYM, closeTo(3, 1e-9));
    });

    test('an out-of-range heading is rejected', () {
      session
        ..updateHeading(999)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      expect(sent.single.single.headingDeg, isNull);
    });

    test('frame ids are unique and payload survives the round trip', () {
      session.addFrame({1: _m(bearing: -12.5, depression: 31.2)});
      clock.advance(ArSessionController.perLotInterval);
      session.addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frames = sent.single;
      expect(frames.map((f) => f.frameId).toSet(), hasLength(frames.length));
      final d = frames.first.detections.single.toJson();
      expect(d['lot'], 1);
      expect(d['bearing_deg'], -12.5);
      expect(d['depression_deg'], 31.2);
      expect(d.containsKey('range_m'), isFalse);
    });
  });

  group('locate mode', () {
    ArPositions positions(Map<int, (double, double)> byLot) => ArPositions(
      byLot: {
        for (final e in byLot.entries)
          e.key: ArLotPosition(
            lotPk: e.key,
            x: e.value.$1,
            y: e.value.$2,
            confidence: 0.9,
          ),
      },
      unsoldTotal: byLot.length,
      unsoldWithPosition: byLot.length,
    );

    /// The measurement a camera at (2,−3) facing +y takes of a landmark.
    ArMeasurement measureFrom(double lx, double ly) {
      const px = 2.0, py = -3.0, theta = math.pi / 2;
      return ArMeasurement(
        bearingDeg:
            -wrapRad(math.atan2(ly - py, lx - px) - theta) * 180 / math.pi,
        depressionDeg: 25,
        quality: 0.9,
      );
    }

    test('no state when locate mode is off', () {
      expect(session.locateState, isNull);
    });

    test('unmapped target', () {
      session
        ..setLocateTarget(9)
        ..updatePositions(positions({1: (0, 0)}));
      expect(session.locateState, isA<LocateUnmapped>());
    });

    test('asks for scans until three mapped lots are sighted, then aims', () {
      session
        ..setLocateTarget(9)
        ..updatePositions(
          positions({1: (0, 0), 2: (4, 0), 3: (1, 3), 9: (2, 1)}),
        );
      expect(session.locateState, isA<LocateNeedScans>());

      session.addFrame({1: measureFrom(0, 0)});
      final oneFix = session.locateState;
      expect(oneFix, isA<LocateNeedScans>());
      expect((oneFix! as LocateNeedScans).fixCount, 1);

      // Two distinct landmarks are not enough for bearing-only resection.
      session.addFrame({2: measureFrom(4, 0)});
      expect((session.locateState! as LocateNeedScans).fixCount, 2);

      session.addFrame({3: measureFrom(1, 3)});
      final aim = session.locateState;
      expect(aim, isA<LocateAim>());
      // Camera at (2,−3) facing +y; target (2,1) is dead ahead, 4 m out.
      final located = aim! as LocateAim;
      expect(located.distanceM, closeTo(4, 0.1));
      expect(located.bearingRightRad.abs(), lessThan(0.05));
    });

    test('turning after the solve swings the arrow by the tracked yaw', () {
      session
        ..setLocateTarget(9)
        ..updatePositions(
          positions({1: (0, 0), 2: (4, 0), 3: (1, 3), 9: (2, 1)}),
        )
        ..addFrame({
          1: measureFrom(0, 0),
          2: measureFrom(4, 0),
          3: measureFrom(1, 3),
        });
      expect(session.locateState, isA<LocateAim>());
      // Turn left 0.5 rad (ccw about gravity, phone upright, starting from
      // yaw 0): the target, previously dead ahead, should now read 0.5 rad
      // to the right.
      session.updateOdometryFromPose(yawRad: 0.5, odoX: 0, odoY: 0);
      final aim = session.locateState! as LocateAim;
      expect(aim.bearingRightRad, closeTo(0.5, 0.05));
    });

    test('sightings of unmapped lots do not count as fixes', () {
      session
        ..setLocateTarget(9)
        ..updatePositions(positions({1: (0, 0), 9: (2, 1)}))
        ..addFrame({55: _m()});
      expect((session.locateState! as LocateNeedScans).fixCount, 0);
    });

    test('stale fixes age out of the window', () {
      session
        ..setLocateTarget(9)
        ..updatePositions(positions({1: (0, 0), 2: (4, 0), 9: (2, 1)}))
        ..addFrame({1: measureFrom(0, 0)});
      clock.advance(ArSessionController.fixWindow + const Duration(seconds: 1));
      session.addFrame({2: measureFrom(4, 0)});
      // Lot 1's fix expired; only lot 2 remains — not enough to orient.
      expect(session.locateState, isA<LocateNeedScans>());
      expect((session.locateState! as LocateNeedScans).fixCount, 1);
    });

    test('updatePositions drops fixes for lots no longer on the map', () {
      session
        ..setLocateTarget(9)
        ..updatePositions(positions({1: (0, 0), 2: (4, 0), 9: (2, 1)}))
        ..addFrame({1: measureFrom(0, 0)})
        ..updatePositions(positions({2: (4, 0), 9: (2, 1)}));
      expect((session.locateState! as LocateNeedScans).fixCount, 0);
    });

    test('lots mapped in a different island are neither fixes nor anchors', () {
      ArPositions islands(Map<int, (double, double, int)> byLot) => ArPositions(
        byLot: {
          for (final e in byLot.entries)
            e.key: ArLotPosition(
              lotPk: e.key,
              x: e.value.$1,
              y: e.value.$2,
              confidence: 0.9,
              component: e.value.$3,
            ),
        },
        unsoldTotal: byLot.length,
        unsoldWithPosition: byLot.length,
      );
      // Lot 3's coordinates live in island 1 — an unrelated frame from the
      // target's island 0, so sighting it must not count toward the fix.
      session
        ..setLocateTarget(9)
        ..updatePositions(islands({1: (0, 0, 0), 3: (1, 3, 1), 9: (2, 1, 0)}))
        ..addFrame({1: measureFrom(0, 0), 3: measureFrom(1, 3)});
      expect((session.locateState! as LocateNeedScans).fixCount, 1);
      expect(session.positionOf(3), isNull);
      expect(session.positionOf(1), isNotNull);
    });
  });

  group('nearby lots (watched/recommended beacons)', () {
    ArPositions positions(Map<int, (double, double)> byLot) => ArPositions(
      byLot: {
        for (final e in byLot.entries)
          e.key: ArLotPosition(
            lotPk: e.key,
            x: e.value.$1,
            y: e.value.$2,
            confidence: 0.9,
          ),
      },
      unsoldTotal: byLot.length,
      unsoldWithPosition: byLot.length,
    );

    /// The measurement a camera at (2,−3) facing +y takes of a landmark.
    ArMeasurement measureFrom(double lx, double ly) {
      const px = 2.0, py = -3.0, theta = math.pi / 2;
      return ArMeasurement(
        bearingDeg:
            -wrapRad(math.atan2(ly - py, lx - px) - theta) * 180 / math.pi,
        depressionDeg: 25,
        quality: 0.9,
      );
    }

    test('nothing is nearby until a pose has been solved', () {
      session
        ..updatePositions(positions({1: (0, 0), 2: (4, 0), 3: (1, 3)}))
        ..addFrame({1: measureFrom(0, 0)});
      expect(session.lotsWithin(100), isEmpty);
    });

    test('the pose is solved with no locate target at all', () {
      session
        ..updatePositions(
          positions({1: (0, 0), 2: (4, 0), 3: (1, 3), 7: (2, -2.5)}),
        )
        ..addFrame({
          1: measureFrom(0, 0),
          2: measureFrom(4, 0),
          3: measureFrom(1, 3),
        });
      expect(session.locateState, isNull); // still not locate mode

      // Camera resected at (2,−3): lot 7 is half a meter ahead, the rest of
      // the map is meters away.
      final near = session.lotsWithin(1.83);
      expect(near.map((l) => l.lotPk), [7]);
      expect(near.single.distanceM, closeTo(0.5, 0.15));

      final aim = session.aimTo(2, 1)!; // dead ahead, 4 m out
      expect(aim.distanceM, closeTo(4, 0.15));
      expect(aim.bearingRightRad.abs(), lessThan(0.05));
    });

    test('lots outside the pose island are never reported as nearby', () {
      session
        ..updatePositions(
          ArPositions(
            byLot: {
              for (final e in {
                1: (0.0, 0.0, 0),
                2: (4.0, 0.0, 0),
                3: (1.0, 3.0, 0),
                // Same coordinates as the camera, but a different island:
                // its numbers mean nothing in this frame.
                8: (2.0, -3.0, 1),
              }.entries)
                e.key: ArLotPosition(
                  lotPk: e.key,
                  x: e.value.$1,
                  y: e.value.$2,
                  confidence: 0.9,
                  component: e.value.$3,
                ),
            },
            unsoldTotal: 4,
            unsoldWithPosition: 4,
          ),
        )
        ..addFrame({
          1: measureFrom(0, 0),
          2: measureFrom(4, 0),
          3: measureFrom(1, 3),
        });
      expect(session.lotsWithin(1.83), isEmpty);
      expect(session.positionOf(8), isNull);
    });
  });

  group('interaction events', () {
    test('each (lot, type) is queued once per session', () {
      session
        ..recordEvent(1, ArEventType.scanned)
        ..recordEvent(1, ArEventType.scanned)
        ..recordEvent(1, ArEventType.zoomed)
        ..recordEvent(2, ArEventType.scanned);
      expect(session.bufferedEvents, 3);
    });

    test('events flush on the interval, even with no frames buffered', () {
      session
        ..recordEvent(1, ArEventType.scanned)
        ..flushIfDue();
      expect(sentEvents, isEmpty); // not due yet
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      expect(sentEvents.single.map((e) => e.toJson()), [
        {'lot': 1, 'event': 'scanned'},
      ]);
      expect(session.bufferedEvents, 0);
    });

    test('a flushed event is not re-queued afterwards', () async {
      session.recordEvent(1, ArEventType.zoomedFull);
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      await Future<void>.value();
      session.recordEvent(1, ArEventType.zoomedFull);
      expect(session.bufferedEvents, 0);
    });
  });
}

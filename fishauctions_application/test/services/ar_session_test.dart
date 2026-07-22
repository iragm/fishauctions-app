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
  late ArSessionController session;

  setUp(() {
    clock = _Clock();
    sent = [];
    session = ArSessionController(
      auctionSlug: 'test-auction',
      sender: (sessionId, frames) async => sent.add(frames),
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

    test('frames record the integrated gyro heading at capture', () {
      // No gyro data yet before the first frame: yaw must be absent, not
      // zero. Then turn left 90° (ccw about gravity, phone upright) and
      // sight lot 2.
      session
        ..addFrame({1: _m()})
        ..integrateGyro(0, math.pi / 2, 0, 1, gx: 0, gy: 9.8, gz: 0)
        ..addFrame({2: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frames = sent.single;
      expect(frames.first.yawDeg, isNull);
      expect(frames.last.yawDeg, closeTo(90, 0.01));
    });

    test('stamps frames with the latest GPS fix and absolute heading', () {
      session
        ..updateLocation(40.5, -79.9)
        ..updateHeading(123.4)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.latitude, 40.5);
      expect(frame.longitude, -79.9);
      expect(frame.headingDeg, 123.4);
    });

    test('a half GPS fix is dropped to null (both or neither)', () {
      session
        ..updateLocation(40.5, null)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.latitude, isNull);
      expect(frame.longitude, isNull);
    });

    test('odometry is omitted until a tracker reading starts it', () {
      session.addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.odoXM, isNull);
      expect(frame.odoYM, isNull);
    });

    test('startOdometry reports the session origin as (0, 0), not absent', () {
      session
        ..startOdometry()
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.odoXM, 0);
      expect(frame.odoYM, 0);
    });

    test(
      'recordSteps advances odometry along the current yaw direction',
      () async {
        session
          ..startOdometry()
          ..recordSteps(2) // straight ahead at yaw 0
          ..addFrame({1: _m()});
        clock.advance(ArSessionController.flushInterval);
        session.flushIfDue();
        final straight = sent.single.single;
        expect(
          straight.odoXM,
          closeTo(2 * ArSessionController.strideLengthM, 1e-9),
        );
        expect(straight.odoYM, closeTo(0, 1e-9));

        // Let flush()'s fire-and-forget `finally` (which resets the in-flight
        // guard) settle before triggering a second cycle — it only needs a
        // microtask in real usage because the event loop pumps between the
        // screen's timer ticks, which a synchronous test body doesn't do.
        await Future<void>.value();

        // Turn left 90° (ccw about gravity) and take one more stride: it should
        // land almost entirely on the +y axis, matching yaw's convention.
        session
          ..integrateGyro(0, math.pi / 2, 0, 1, gx: 0, gy: 9.8, gz: 0)
          ..recordSteps(1)
          ..addFrame({2: _m()});
        clock.advance(ArSessionController.flushInterval);
        session.flushIfDue();
        final turned = sent[1].single;
        expect(
          turned.odoXM,
          closeTo(2 * ArSessionController.strideLengthM, 1e-6),
        );
        expect(turned.odoYM, closeTo(ArSessionController.strideLengthM, 1e-6));
      },
    );

    test('recordSteps before startOdometry is a no-op — no fake tracker', () {
      session
        ..recordSteps(5)
        ..addFrame({1: _m()});
      clock.advance(ArSessionController.flushInterval);
      session.flushIfDue();
      final frame = sent.single.single;
      expect(frame.odoXM, isNull);
      expect(frame.odoYM, isNull);
    });

    test(
      'invalidateOdometry stops the channel for good (tracker reset)',
      () async {
        session
          ..startOdometry()
          ..recordSteps(3)
          ..invalidateOdometry()
          ..addFrame({1: _m()});
        clock.advance(ArSessionController.flushInterval);
        session.flushIfDue();
        final afterReset = sent.single.single;
        expect(afterReset.odoXM, isNull);
        expect(afterReset.odoYM, isNull);

        // See the previous test: yield a microtask so flush()'s fire-and-forget
        // `finally` settles before a second cycle in the same test body.
        await Future<void>.value();

        // Further calls — even a fresh startOdometry — must not resurrect it;
        // the session must never mix two different tracker origins.
        session
          ..startOdometry()
          ..recordSteps(1)
          ..addFrame({2: _m()});
        clock.advance(ArSessionController.flushInterval);
        session.flushIfDue();
        final stillNull = sent[1].single;
        expect(stillNull.odoXM, isNull);
        expect(stillNull.odoYM, isNull);
      },
    );

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
      session.setLocateTarget(9, positions({1: (0, 0)}));
      expect(session.locateState, isA<LocateUnmapped>());
    });

    test('asks for scans until three mapped lots are sighted, then aims', () {
      session.setLocateTarget(
        9,
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

    test('turning after the solve swings the arrow by the gyro yaw', () {
      session
        ..setLocateTarget(
          9,
          positions({1: (0, 0), 2: (4, 0), 3: (1, 3), 9: (2, 1)}),
        )
        ..addFrame({
          1: measureFrom(0, 0),
          2: measureFrom(4, 0),
          3: measureFrom(1, 3),
        });
      expect(session.locateState, isA<LocateAim>());
      // Turn left 0.5 rad (ccw about gravity, phone upright): the target,
      // previously dead ahead, should now read 0.5 rad to the right.
      session.integrateGyro(0, 0.5, 0, 1, gx: 0, gy: 9.8, gz: 0);
      final aim = session.locateState! as LocateAim;
      expect(aim.bearingRightRad, closeTo(0.5, 0.05));
    });

    test('sightings of unmapped lots do not count as fixes', () {
      session
        ..setLocateTarget(9, positions({1: (0, 0), 9: (2, 1)}))
        ..addFrame({55: _m()});
      expect((session.locateState! as LocateNeedScans).fixCount, 0);
    });

    test('stale fixes age out of the window', () {
      session
        ..setLocateTarget(9, positions({1: (0, 0), 2: (4, 0), 9: (2, 1)}))
        ..addFrame({1: measureFrom(0, 0)});
      clock.advance(ArSessionController.fixWindow + const Duration(seconds: 1));
      session.addFrame({2: measureFrom(4, 0)});
      // Lot 1's fix expired; only lot 2 remains — not enough to orient.
      expect(session.locateState, isA<LocateNeedScans>());
      expect((session.locateState! as LocateNeedScans).fixCount, 1);
    });

    test('updatePositions drops fixes for lots no longer on the map', () {
      session
        ..setLocateTarget(9, positions({1: (0, 0), 2: (4, 0), 9: (2, 1)}))
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
        ..setLocateTarget(
          9,
          islands({1: (0, 0, 0), 3: (1, 3, 1), 9: (2, 1, 0)}),
        )
        ..addFrame({1: measureFrom(0, 0), 3: measureFrom(1, 3)});
      expect((session.locateState! as LocateNeedScans).fixCount, 1);
      expect(session.positionOf(3), isNull);
      expect(session.positionOf(1), isNotNull);
    });
  });
}

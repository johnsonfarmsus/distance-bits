import 'dart:typed_data';

import 'package:distance_bits/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 96×72 front-camera frame: dim scene, optional torch spot, optional lamp.
RgbaImage frame({bool torch = false, int tx = 40, int ty = 30, bool lamp = false, int lampLevel = 255, int sceneLevel = 30, Prng? noise}) {
  const w = 96, h = 72;
  final d = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    final v = noise == null ? sceneLevel : (sceneLevel + noise.nextInt(20)).clamp(0, 255);
    d[i * 4] = v;
    d[i * 4 + 1] = v;
    d[i * 4 + 2] = v;
    d[i * 4 + 3] = 255;
  }
  void box(int x0, int y0, int bw, int bh, int r, int g, int b) {
    for (var y = y0; y < y0 + bh; y++) {
      for (var x = x0; x < x0 + bw; x++) {
        final o = (y * w + x) * 4;
        d[o] = r;
        d[o + 1] = g;
        d[o + 2] = b;
      }
    }
  }

  if (lamp) box(70, 2, 18, 6, lampLevel, lampLevel, lampLevel);
  if (torch) box(tx, ty, 3, 3, 255, 255, 255);
  return RgbaImage(d, w, h);
}

/// Runs a detector over [seconds] of 30 fps frames; returns the time of detection (ms) or null.
double? run(RgbaImage Function(double tMs, int i) f, {double seconds = 4, double fps = 30}) {
  final det = AckDetector();
  for (var i = 0; i < seconds * fps; i++) {
    final t = i * 1000 / fps;
    if (det.add(f(t, i), t)) return t;
  }
  return null;
}

void main() {
  bool torchOn(double t, double start) => t >= start && t < start + ackDurationMs && ((t - start) ~/ ackHalfPeriodMs).isEven;

  test('the ack rhythm is detected within about 1.5 s', () {
    final t = run((t, _) => frame(torch: torchOn(t, 500)));
    expect(t, isNotNull);
    expect(t!, lessThan(500 + 1600));
  });

  test('detected at 60 fps and at an uneven 24 fps too', () {
    expect(run((t, _) => frame(torch: torchOn(t, 0)), fps: 60), isNotNull);
    expect(run((t, _) => frame(torch: torchOn(t, 0)), fps: 24), isNotNull);
  });

  test('receiver timer jitter (±20 ms per blink) is tolerated', () {
    final rng = Prng(9);
    final edges = <double>[0];
    while (edges.last < ackDurationMs) {
      edges.add(edges.last + ackHalfPeriodMs + (rng.next() * 40 - 20));
    }
    bool on(double t) {
      for (var k = 0; k < edges.length - 1; k++) {
        if (t >= edges[k] && t < edges[k + 1]) return k.isEven;
      }
      return false;
    }

    expect(run((t, _) => frame(torch: on(t))), isNotNull);
  });

  test('a hand-held torch drifting slowly is still detected', () {
    expect(run((t, i) => frame(torch: torchOn(t, 0), tx: 30 + i ~/ 6, ty: 28 + i ~/ 10)), isNotNull);
  });

  test('a steady lamp is not an ack', () {
    expect(run((t, _) => frame(lamp: true)), isNull);
  });

  test('a mains-flickering lamp, aliased by the camera, is not an ack', () {
    // 120 Hz flicker sampled at 30 fps beats slowly; model it as a slow wobble crossing saturation.
    expect(run((t, _) => frame(lamp: true, lampLevel: (230 + 25 * (t / 900 % 1)).round())), isNull);
  });

  test('screen-like flashing at 15–30 Hz is not an ack', () {
    // Reflections of the sender's own screen toggling every frame or two.
    expect(run((t, i) => frame(torch: (i ~/ 1).isEven)), isNull);
    expect(run((t, i) => frame(torch: (i ~/ 2).isEven, tx: 10)), isNull);
  });

  test('a big bright area (sunlit wall) is not a torch', () {
    expect(run((t, _) => frame(sceneLevel: torchOn(t, 0) ? 250 : 30)), isNull);
  });

  test('random sensor noise is not an ack', () {
    final rng = Prng(4);
    expect(run((t, _) => frame(noise: rng)), isNull);
  });
}

// A Far-mode sequence rebuilt from a real receiver frame (14 Pro, 8 Oct 2026,
// 21:37: dark room, lamp behind, red screen at arm's length): the screen pixels
// are recoloured white / black to make symbols and separators, and the whole
// frame is brightened/darkened the way the exposure sweep did (ISO 114–1000).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:distance_bits/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'field_snapshot_test.dart' show loadPpm;

void main() {
  final base = loadPpm('test/fixtures/field-2026-10-08-far-dark/red-screen.ppm'); // plain load: no expect() here
  final w = base.width, h = base.height;
  // The red screen in this frame: strongly red pixels.
  final isScreen = List<bool>.generate(w * h, (i) {
    final r = base.data[i * 4], g = base.data[i * 4 + 1];
    return r > 120 && g < 70;
  });

  RgbaImage frame(String what, double gain) {
    final out = Uint8List.fromList(base.data);
    for (var i = 0; i < w * h; i++) {
      if (isScreen[i]) {
        final (r, g, b) = switch (what) { 'W' => (230, 190, 163), 'R' => (184, 31, 17), _ => (4, 4, 4) };
        out[i * 4] = r;
        out[i * 4 + 1] = g;
        out[i * 4 + 2] = b;
      }
      for (var c = 0; c < 3; c++) {
        out[i * 4 + c] = (out[i * 4 + c] * gain).round().clamp(0, 255);
      }
    }
    return RgbaImage(out, w, h);
  }

  test('real-frame Far sequence: the box is the screen, not the lamp and not a speck', () {
    // Screen bounding box in this frame.
    var x0 = w, x1 = 0, y0 = h, y1 = 0;
    for (var i = 0; i < w * h; i++) {
      if (!isScreen[i]) continue;
      final x = i % w, y = i ~/ w;
      x0 = math.min(x0, x);
      x1 = math.max(x1, x);
      y0 = math.min(y0, y);
      y1 = math.max(y1, y);
    }
    final finder = ScreenFinder();
    final symbols = 'RWRRWRWWWWWWRWRRWRWWWWWWWWRRW'.split('');
    final gains = [1.0, 0.4, 1.0, 2.0, 1.0]; // exposure sweep before the screen is found
    var t = 0.0, lit = 0, good = 0;
    final bad = <String>[];
    for (var k = 0; k < symbols.length; k++) {
      final gain = gains[(k ~/ 6) % gains.length];
      for (final part in [symbols[k], 'K']) {
        for (var shot = 0; shot < 4; shot++, t += 16.7) {
          final box = finder.find(frame(part, gain), t);
          if (part != 'K' && k >= 6) {
            lit++;
            final onScreen = box != null && (box.x - x0).abs() <= 3 && (box.y - y0).abs() <= 3 && (box.w - (x1 - x0 + 1)).abs() <= 6 && (box.h - (y1 - y0 + 1)).abs() <= 6;
            if (onScreen) {
              good++;
            } else {
              bad.add('t=${t.toStringAsFixed(0)} $part gain $gain: $box');
            }
          }
        }
      }
    }
    expect(good, greaterThanOrEqualTo((lit * 0.9).round()), reason: 'screen ${x0},${y0} ${x1 - x0 + 1}x${y1 - y0 + 1}; misses: ${[for (var i = 0; i < bad.length; i += 6) bad[i]].join(' | ')}');
  });
}

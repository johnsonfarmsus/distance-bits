// Real receiver camera frames (14 Pro, 8 Oct 2026, Far mode, phone held at arm's
// length in a lit tiled room). Snapshots 1/3 white screen, 5 red screen, 0/2 screen
// dark (separator) with the room visible, 4 phone out of view.
import 'dart:io';
import 'dart:typed_data';

import 'package:distance_bits/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

RgbaImage loadPpm(String path) {
  final b = File(path).readAsBytesSync();
  var pos = 0;
  String token() {
    while (b[pos] == 0x20 || b[pos] == 0x0a || b[pos] == 0x0d || b[pos] == 0x09) {
      pos++;
    }
    final start = pos;
    while (!(b[pos] == 0x20 || b[pos] == 0x0a || b[pos] == 0x0d || b[pos] == 0x09)) {
      pos++;
    }
    return String.fromCharCodes(b.sublist(start, pos));
  }

  expect(token(), 'P6');
  final w = int.parse(token()), h = int.parse(token());
  token(); // maxval
  pos++; // single whitespace before pixel data
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    out[i * 4] = b[pos + i * 3];
    out[i * 4 + 1] = b[pos + i * 3 + 1];
    out[i * 4 + 2] = b[pos + i * 3 + 2];
    out[i * 4 + 3] = 255;
  }
  return RgbaImage(out, w, h);
}

RgbaImage snap(int n) => loadPpm('test/fixtures/field-2026-10-08-far/snap-2026-10-08T21-09-22-$n.ppm');

void main() {
  test('lit screen: the box is the phone screen, not the wall or the hand', () {
    final finder = ScreenFinder();
    // A small seed in the middle of the phone, as if only part of it had switched colour.
    const seed = ScreenRect(95, 230, 10, 10);
    for (final n in [1, 3, 5]) {
      final (box, peak) = finder.screenBoxAround(snap(n), seed)!;
      // The phone screen spans x ≈ 65–200, y ≈ 143–378 across these frames.
      expect(box.x, inInclusiveRange(60, 85), reason: 'snap $n: $box (peak $peak)');
      expect(box.w, inInclusiveRange(100, 135), reason: 'snap $n: $box');
      expect(box.y, inInclusiveRange(140, 152), reason: 'snap $n: $box');
      expect(box.h, inInclusiveRange(220, 236), reason: 'snap $n: $box');
    }
  });

  test('screen dark or gone: the box never balloons onto the room', () {
    final finder = ScreenFinder();
    // White and red frames alternate (Far symbols): colour switching at the phone.
    var t = 0.0;
    ScreenRect? last;
    for (var i = 0; i < 10; i++) {
      last = finder.find(snap(i.isEven ? 3 : 5), t) ?? last;
      t += 66.7;
    }
    expect(last, isNotNull);
    expect(last!.w, lessThan(140), reason: '$last');
    // Screen black, room visible (separator frames), then the phone out of view.
    for (final n in [0, 2, 4]) {
      final box = finder.find(snap(n), t);
      t += 66.7;
      if (box != null) {
        expect(box.w * box.h, lessThan(2.5 * 140 * 236), reason: 'snap $n ballooned: $box');
      }
    }
  });
}

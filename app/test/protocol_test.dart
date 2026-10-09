import 'dart:typed_data';

import 'package:distance_bits/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> cellsFor(Frame f, Config cfg) {
  final p = presets[cfg.preset]!;
  return f.layout == Layout.blob ? List.filled(p.cols * p.rows, f.cells[0]) : f.cells;
}

({Uint8List? bytes, int frames, Receiver rx, Uint8List payload}) run(
  Config cfg,
  String text, {
  double loss = 0,
  int seed = 1,
  bool manual = false,
  int skip = 0,
  int maxFrames = 20000,
  double jitterMs = 0,
  double colourErr = 0,
  bool dropBeacons = false,
}) {
  final payload = encodePayload(Payload.text(text));
  final tx = Transmitter(cfg, payload, msgId: 123);
  Uint8List? got;
  final rx = Receiver(events: ReceiverEvents(onDone: (_, b, __) => got = b), manualConfig: manual ? cfg : null);
  final rng = Prng(seed);
  final pal = palettes[cfg.palette]!;
  final period = framePeriodMs(cfg.fps);
  var frames = 0;
  for (var i = 0; i < maxFrames && got == null; i++) {
    final f = tx.next();
    frames++;
    if (i < skip) continue;
    if (loss > 0 && rng.next() < loss) continue;
    if (dropBeacons && f.segment == Segment.beacon) continue;
    var cells = cellsFor(f, cfg);
    if (colourErr > 0 && f.segment != Segment.beacon) {
      cells = [
        for (final c in cells)
          c != Col.k && rng.next() < colourErr ? pal[(pal.indexOf(c) + 1 + rng.nextInt(pal.length - 1)) % pal.length] : c,
      ];
    }
    final t = f.seq * period + (jitterMs > 0 ? (rng.next() * 2 - 1) * jitterMs : 0);
    rx.observe(Observation(t, cells));
  }
  return (bytes: got, frames: frames, rx: rx, payload: payload);
}

void main() {
  const text = 'Meet at the north gate at 7. Bring the long lens.';

  for (final preset in PresetName.values) {
    for (final palette in PaletteName.values) {
      test('${preset.name}/${palette.name}: lossless, auto-config from beacon', () {
        final cfg = defaultConfig(preset).copyWith(palette: palette);
        final r = run(cfg, text);
        expect(r.bytes, r.payload);
        expect(r.rx.config, cfg);
        expect(r.rx.stats.beacons, greaterThan(0));
      });
    }
  }

  test('near: 15% frame loss with jitter', () {
    final r = run(defaultConfig(PresetName.near), text, loss: 0.15, jitterMs: 8, seed: 3);
    expect(r.bytes, r.payload);
  });

  test('mid: 10% frame loss', () {
    final r = run(defaultConfig(PresetName.mid), 'short msg', loss: 0.1, seed: 5, jitterMs: 6);
    expect(r.bytes, r.payload);
  });

  test('far: 10% frame loss at 15 fps', () {
    final r = run(defaultConfig(PresetName.far), 'ok?', loss: 0.1, seed: 8, jitterMs: 10);
    expect(r.bytes, r.payload);
  });

  for (final preset in [PresetName.near, PresetName.mid]) {
    test('${preset.name}: no beacon, 25% frame loss: auto-config holds and decodes', () {
      // Field log 8 Oct: missed frames made the fps guess flip to 10, and every flip
      // reset the stream. Auto-detect alone must now cope with heavy loss.
      final r = run(defaultConfig(preset), 'hello from distance bits', loss: 0.25, seed: 4, jitterMs: 6, dropBeacons: true, maxFrames: 60000);
      expect(r.bytes, r.payload);
      expect(r.rx.config, defaultConfig(preset));
    });
  }

  test('joining mid-stream without config waits for the next beacon', () {
    final r = run(defaultConfig(PresetName.near).copyWith(palette: PaletteName.rgw), text, skip: 100);
    expect(r.bytes, r.payload);
  });

  for (final preset in PresetName.values) {
    test('${preset.name}: 2% random colour errors never produce a wrong message', () {
      for (final seed in [1, 2, 3]) {
        final r = run(defaultConfig(preset), preset == PresetName.far ? 'ok?' : text, colourErr: 0.02, seed: seed, maxFrames: 60000);
        expect(r.bytes, r.payload);
      }
    });
  }

  test('"hi" at Far decodes in under 30 s of frames', () {
    final cfg = defaultConfig(PresetName.far);
    final r = run(cfg, 'hi');
    expect(r.bytes, r.payload);
    expect(r.frames / cfg.fps, lessThan(30));
  });

  test('an 8 KB payload decodes with 5% loss', () {
    final r = run(defaultConfig(PresetName.near), 'x' * 8000, loss: 0.05, seed: 11, maxFrames: 200000);
    expect(r.bytes, r.payload);
  });

  test('screen finder picks the colour-changing screen over a bigger, brighter, flickering lamp', () {
    // Field test 8 Oct (hallway): ceiling lights outshine the phone, and the old
    // "largest bright blob" locked onto them.
    final cfg = defaultConfig(PresetName.near);
    final tx = Transmitter(cfg, encodePayload(Payload.text('lamp test')), msgId: 3);
    final finder = ScreenFinder();
    final rng = Prng(7);
    ScreenRect? found;
    const w = 120, h = 160;
    for (var i = 0; i < 40; i++) {
      final f = tx.next();
      final img = RgbaImage(Uint8List(w * h * 4), w, h);
      for (var p = 0; p < w * h; p++) {
        img.data[p * 4 + 3] = 255;
      }
      // Warm-white lamp, 50×20 px, brightness flickering 60–100 % with a little hue wobble.
      final k = 0.6 + 0.4 * rng.next();
      for (var y = 5; y < 25; y++) {
        for (var x = 30; x < 80; x++) {
          final o = (y * w + x) * 4;
          img.data[o] = (255 * k).round();
          img.data[o + 1] = (235 * k * (0.97 + 0.06 * rng.next())).round().clamp(0, 255);
          img.data[o + 2] = (180 * k).round();
        }
      }
      // The sender: 14×28 px, dimmer than the lamp, cells per the transmitted frame.
      final cells = cellsFor(f, cfg);
      for (var y = 0; y < 28; y++) {
        for (var x = 0; x < 14; x++) {
          final rgb = colorRgb[cells[(y * 4 ~/ 28) * 2 + (x * 2 ~/ 14)]];
          final o = ((100 + y) * w + 50 + x) * 4;
          img.data[o] = (((rgb >> 16) & 0xff) * 0.7).round();
          img.data[o + 1] = (((rgb >> 8) & 0xff) * 0.7).round();
          img.data[o + 2] = ((rgb & 0xff) * 0.7).round();
        }
      }
      found = finder.find(img, i * 33.3);
    }
    expect(found, isNotNull);
    expect(found!.y, greaterThanOrEqualTo(95), reason: 'found $found, expected the screen at 50,100 14x28');
    expect(found.x, inInclusiveRange(45, 55));
  });

  test('pixel pipeline decodes a rendered near frame stream', () {
    // Paint frames into a small synthetic camera image and run the full pipeline.
    final cfg = defaultConfig(PresetName.near);
    final tx = Transmitter(cfg, encodePayload(Payload.text('pixels')), msgId: 9);
    String? got;
    final pipe = RxPipeline(onDone: (p, _, __) => got = p.text);
    const w = 80, h = 60;
    for (var i = 0; i < 3000 && got == null; i++) {
      final f = tx.next();
      final img = RgbaImage(Uint8List(w * h * 4), w, h);
      for (var p = 0; p < w * h; p++) {
        img.data[p * 4] = 26;
        img.data[p * 4 + 1] = 24;
        img.data[p * 4 + 2] = 22;
        img.data[p * 4 + 3] = 255;
      }
      final cells = cellsFor(f, cfg);
      const rx0 = 30, ry0 = 10, rw = 20, rh = 40;
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x++) {
          final c = cells[(y * 4 ~/ rh) * 2 + (x * 2 ~/ rw)];
          final rgb = colorRgb[c];
          final o = ((ry0 + y) * w + rx0 + x) * 4;
          img.data[o] = (rgb >> 16) & 0xff;
          img.data[o + 1] = (rgb >> 8) & 0xff;
          img.data[o + 2] = rgb & 0xff;
        }
      }
      // Two captures per transmitted frame, like a 60 fps camera on a 30 fps sender.
      pipe.process(img, f.seq * 1000 / 30);
      pipe.process(img, f.seq * 1000 / 30 + 16);
    }
    expect(got, 'pixels');
  });
}

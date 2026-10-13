// Far-mode range simulation built on the real arm's-length run (14 Pro receiving,
// 8 Oct 2026 21:47, "Oh" decoded). The background is the real dark frame from
// that run (lamp included); the screen is drawn with the colours measured in
// that run's log (R ≈ ee210b, W ≈ e6c3aa, black screen ≈ 030201), at the 12 Pro's
// aspect ratio, with area-weighted edges and display scan-out tearing. Only the
// screen's size changes, which is what distance changes. The pipeline is the
// app's: coarse image (every 3rd pixel of 720×1280) for finding, full-resolution
// cell sampling (as CamFrame.sampleCells) for reading.
//
// Run: flutter test test/range_sim_test.dart --dart-define=RANGE_TABLE=1
// (prints a table, ~5 min). Without the define only the arm's-length baseline
// runs, which pins the simulation to the real run.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:distance_bits/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'field_snapshot_test.dart' show loadPpm;

const step = 3; // coarse step, as the app at 720p
const capMs = 1000 / 125; // measured capture rate ~120–138 fps
const scanMs = 1000 / 120; // display scan-out time (ProMotion 120 Hz)
const aspect = 2532 / 1170; // 12 Pro panel

final rgbOf = <int, List<int>>{
  Col.k: [3, 2, 1],
  Col.w: [230, 195, 170],
  Col.r: [238, 33, 11],
};

class Sim {
  final RgbaImage bg; // coarse background (real frame)
  final int fw, fh; // full-res size
  final double s; // screen width in full-res px
  final double jitter; // px, std of hand shake per capture (smoothed)
  final math.Random rnd;
  double cx, cy, vx = 0, vy = 0;
  Sim(this.bg, this.s, {this.jitter = 0, int seed = 1})
      : fw = bg.width * step,
        fh = bg.height * step,
        cx = bg.width * step * 0.47,
        cy = bg.height * step * 0.55,
        rnd = math.Random(seed);

  // Screen state for this capture: new colour above the scan line, old below.
  late List<int> top, bottom;
  late double splitY; // full-res y of the scan line (screen-relative fraction mapped)
  double get sw => s;
  double get sh => s * aspect;
  double get x0 => cx - sw / 2;
  double get y0 => cy - sh / 2;

  void move() {
    if (jitter == 0) return;
    // Smoothed random walk pulled back to the start point.
    // jitter = rms speed in full-res px per second: smoothed random velocity
    // (~0.2 s correlation), weakly pulled back to the start point.
    const a = 0.96; // per capture (8 ms): ~200 ms correlation
    final kick = jitter * capMs / 1000 * math.sqrt(1 - a * a);
    vx = a * vx + kick * _g();
    vy = a * vy + kick * _g();
    cx += vx - 0.002 * (cx - fw * 0.47);
    cy += vy - 0.002 * (cy - fh * 0.55);
  }

  double _g() {
    final u = rnd.nextDouble() + 1e-12, v = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  int bgAt(int x, int y) {
    final i = ((y ~/ step).clamp(0, bg.height - 1) * bg.width + (x ~/ step).clamp(0, bg.width - 1)) * 4;
    return (bg.data[i] << 16) | (bg.data[i + 1] << 8) | bg.data[i + 2];
  }

  /// Full-res pixel: area-weighted mix of screen and background.
  int px(int x, int y) {
    final ox = math.max(0.0, math.min(x + 1.0, x0 + sw) - math.max(x.toDouble(), x0));
    final oy = math.max(0.0, math.min(y + 1.0, y0 + sh) - math.max(y.toDouble(), y0));
    final b = bgAt(x, y);
    final f = ox * oy;
    if (f <= 0) return b;
    final c = (y + 0.5) < splitY ? top : bottom;
    int mix(int sc, int bc) => (f * sc + (1 - f) * bc).round().clamp(0, 255);
    return (mix(c[0], (b >> 16) & 0xff) << 16) | (mix(c[1], (b >> 8) & 0xff) << 8) | mix(c[2], b & 0xff);
  }

  RgbaImage coarse() {
    final out = Uint8List.fromList(bg.data);
    final cx0 = math.max(0, (x0 / step).floor() - 1), cx1 = math.min(bg.width - 1, ((x0 + sw) / step).ceil() + 1);
    final cy0 = math.max(0, (y0 / step).floor() - 1), cy1 = math.min(bg.height - 1, ((y0 + sh) / step).ceil() + 1);
    for (var y = cy0; y <= cy1; y++) {
      for (var x = cx0; x <= cx1; x++) {
        final c = px(x * step, y * step), i = (y * bg.width + x) * 4;
        out[i] = (c >> 16) & 0xff;
        out[i + 1] = (c >> 8) & 0xff;
        out[i + 2] = c & 0xff;
      }
    }
    return RgbaImage(out, bg.width, bg.height);
  }

  /// Same arithmetic as CamFrame.sampleCells.
  List<Rgb> sample(ScreenRect r, int cols, int rows, {double inset = 0.25, int maxPts = 10}) {
    final out = <Rgb>[];
    final cw = r.w / cols, ch = r.h / rows;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final xa = (r.x + col * cw + cw * inset).round(), xb = (r.x + (col + 1) * cw - cw * inset).round();
        final ya = (r.y + row * ch + ch * inset).round(), yb = (r.y + (row + 1) * ch - ch * inset).round();
        final sx = ((xb - xa) / maxPts).ceil().clamp(1, 1 << 20), sy = ((yb - ya) / maxPts).ceil().clamp(1, 1 << 20);
        var sr = 0, sg = 0, sb = 0, n = 0;
        for (var y = ya; y <= yb || n == 0; y += sy) {
          if (y >= fh) break;
          if (y < 0) continue;
          for (var x = xa; x <= xb; x += sx) {
            if (x < 0 || x >= fw) continue;
            final c = px(x, y);
            sr += (c >> 16) & 0xff;
            sg += (c >> 8) & 0xff;
            sb += c & 0xff;
            n++;
          }
          if (y > yb) break;
        }
        out.add(n > 0 ? (sr / n, sg / n, sb / n) : (0, 0, 0));
      }
    }
    return out;
  }
}

class Result {
  final String? text;
  final double? doneMs, headerMs;
  final int litFrames, litFound, accepted, crcFails;
  String csv = '';
  Result(this.text, this.doneMs, this.headerMs, this.litFrames, this.litFound, this.accepted, this.crcFails);
}

Result run(RgbaImage bg, double s, String text, {double jitter = 0, int seed = 1, double maxMs = 60000, bool log = false}) {
  final cfg = defaultConfig(PresetName.far);
  final tx = Transmitter(cfg, encodePayload(Payload.text(text)), msgId: 42);
  String? got;
  double? doneAt, headerAt;
  var crc = 0;
  var t = 0.0;
  final pipe = RxPipeline(
    onDone: (p, _, __) {
      got ??= p.text;
      doneAt ??= t;
    },
    onHeader: (_) => headerAt ??= t,
    onCrcFail: (_, __) => crc++,
  );
  pipe.keepLog = log;
  final sim = Sim(bg, s, jitter: jitter, seed: seed);
  final period = 1000 / cfg.fps;
  // Transmitter starts at a random phase relative to the receiver.
  final phase = math.Random(seed).nextDouble() * period;
  var frameIdx = -1;
  var cur = Col.k, prev = Col.k;
  var lit = 0, found = 0;
  final jr = math.Random(seed + 7);
  for (t = 0; t < maxMs && got == null; t += capMs + (jr.nextDouble() - 0.5) * 2) {
    final k = ((t + phase) / period).floor();
    while (frameIdx < k) {
      prev = cur;
      cur = tx.next().cells[0];
      frameIdx++;
    }
    final since = (t + phase) - k * period;
    // Scan-out top to bottom over scanMs: rows above the line show the new frame.
    final frac = (since / scanMs).clamp(0.0, 1.0);
    sim.move();
    sim.top = rgbOf[cur]!;
    sim.bottom = frac >= 1 ? rgbOf[cur]! : rgbOf[prev]!;
    sim.splitY = sim.y0 + frac * sim.sh;
    if (frac >= 1) sim.splitY = double.infinity;
    final rec = pipe.process(sim.coarse(), t,
        sampler: (r, cols, rows, keep) => sim.sample(fullResRect(r, step, keep: keep), cols, rows));
    if (cur != Col.k && frac >= 1) {
      lit++;
      if (rec.rect != null) found++;
    }
  }
  return Result(got, doneAt, headerAt, lit, found, pipe.accepted, crc)..csv = log ? pipe.csv() : '';
}

/// Distance at which a 65 mm wide screen spans [s] px of a 720 px wide frame
/// whose width covers [fovDeg] (14 Pro main camera at 16:9 crop, portrait ≈ 45°).
double metres(double s, {double fovDeg = 45.6, double zoom = 1}) {
  final perPx = 2 * math.tan(fovDeg / 2 * math.pi / 180) / zoom / 720;
  return 0.065 / (s * perPx);
}

void main() {
  final bg = loadPpm('test/fixtures/field-2026-10-08-far-s9/dark.ppm');

  test('arm\'s-length baseline decodes (matches the real run)', () {
    final r = run(bg, 219, 'Oh');
    expect(r.text, 'Oh');
    expect(r.doneMs, lessThan(35000)); // the real run: ~30 s from first symbols
  });

  test('one case (--dart-define=SIM=size,jitter,text)', () {
    const spec = String.fromEnvironment('SIM');
    if (spec.isEmpty) return;
    final p = spec.split(',');
    final r = run(bg, double.parse(p[0]), p.sublist(2).join(','), jitter: double.parse(p[1]), seed: double.parse(p[0]).round(), log: true);
    File('${Directory.systemTemp.path}/sim-case.csv').writeAsStringSync(r.csv);
    // ignore: avoid_print
    print('case $spec: ${r.text} header ${r.headerMs?.round()} done ${r.doneMs?.round()} found ${r.litFound}/${r.litFrames} accepted ${r.accepted} crc ${r.crcFails}');
  });

  test('range table', () {
    // Takes ~5 min: only with --dart-define=RANGE_TABLE=1.
    if (!const bool.fromEnvironment('RANGE_TABLE')) return;
    final rows = <String>['size(px)  ~m@1x  ~m@3x  px/s    text            decoded  header_s  done_s  litFound  crcFails'];
    for (final s in <double>[219, 100, 50, 30, 20, 14, 11, 9, 8, 7, 6, 5]) {
      for (final j in [0.0, 10.0, 40.0]) {
        for (final text in ['Oh', 'see you at 6']) {
          final r = run(bg, s, text, jitter: j, seed: s.round());
          rows.add([
            s.toStringAsFixed(0).padLeft(8),
            metres(s).toStringAsFixed(1).padLeft(6),
            metres(s, zoom: 3).toStringAsFixed(1).padLeft(6),
            j.toStringAsFixed(0).padLeft(6),
            text.padRight(14),
            (r.text == text ? 'yes' : 'NO').padLeft(7),
            (r.headerMs == null ? '-' : (r.headerMs! / 1000).toStringAsFixed(1)).padLeft(8),
            (r.doneMs == null ? '-' : (r.doneMs! / 1000).toStringAsFixed(1)).padLeft(7),
            '${(100 * r.litFound / math.max(1, r.litFrames)).round()}%'.padLeft(8),
            '${r.crcFails}'.padLeft(9),
          ].join('  '));
        }
      }
    }
    // ignore: avoid_print
    print(rows.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 20)));
}

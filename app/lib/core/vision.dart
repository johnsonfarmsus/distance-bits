import 'dart:math' as math;
import 'dart:typed_data';

import 'colors.dart';

/// RGBA pixel buffer (same layout as canvas ImageData).
class RgbaImage {
  final Uint8List data;
  final int width, height;
  RgbaImage(this.data, this.width, this.height);
}

class ScreenRect {
  final int x, y, w, h;
  const ScreenRect(this.x, this.y, this.w, this.h);
  @override
  String toString() => '$x:$y:$w:$h';
}

typedef Rgb = (double, double, double);

/// Find the transmitting screen: the largest bright connected blob (port of vision.ts).
ScreenRect? findScreen(RgbaImage img, {int minArea = 12}) {
  final data = img.data, width = img.width, height = img.height;
  final n = width * height;
  final v = Uint8List(n);
  var sum = 0, max = 0;
  for (var i = 0; i < n; i++) {
    final r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2];
    final m = r > g ? (r > b ? r : b) : (g > b ? g : b);
    v[i] = m;
    sum += m;
    if (m > max) max = m;
  }
  final mean = sum / n;
  if (max - mean < 40) return null;
  final thr = mean + 0.25 * (max - mean);
  final label = Int32List(n)..fillRange(0, n, -1);
  ScreenRect? best;
  var bestArea = 0;
  final stack = <int>[];
  var comp = 0;
  for (var start = 0; start < n; start++) {
    if (v[start] < thr || label[start] >= 0) continue;
    var minX = width, minY = height, maxX = 0, maxY = 0, area = 0;
    stack.add(start);
    label[start] = comp;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final x = p % width, y = p ~/ width;
      area++;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (x > 0) _visit(p - 1, v, label, thr, comp, stack);
      if (x < width - 1) _visit(p + 1, v, label, thr, comp, stack);
      if (y > 0) _visit(p - width, v, label, thr, comp, stack);
      if (y < height - 1) _visit(p + width, v, label, thr, comp, stack);
    }
    if (area > bestArea) {
      bestArea = area;
      best = ScreenRect(minX, minY, maxX - minX + 1, maxY - minY + 1);
    }
    comp++;
  }
  if (best == null || bestArea < minArea) return null;
  return best;
}

void _visit(int q, Uint8List v, Int32List label, double thr, int comp, List<int> stack) {
  if (label[q] >= 0 || v[q] < thr) return;
  label[q] = comp;
  stack.add(q);
}

/// Union of recent detections, held through black frames.
class RectTracker {
  final List<(double, ScreenRect)> _recent = [];
  double windowMs, holdMs;
  RectTracker({this.windowMs = 400, this.holdMs = 1500});

  ScreenRect? update(ScreenRect? found, double t) {
    if (found != null) _recent.add((t, found));
    _recent.removeWhere((e) => t - e.$1 > holdMs);
    if (_recent.isEmpty) return null;
    var use = _recent.where((e) => t - e.$1 <= windowMs).toList();
    if (use.isEmpty) use = [_recent.last];
    var x0 = 1 << 30, y0 = 1 << 30, x1 = -(1 << 30), y1 = -(1 << 30);
    for (final (_, r) in use) {
      x0 = math.min(x0, r.x);
      y0 = math.min(y0, r.y);
      x1 = math.max(x1, r.x + r.w);
      y1 = math.max(y1, r.y + r.h);
    }
    return ScreenRect(x0, y0, x1 - x0, y1 - y0);
  }

  void reset() => _recent.clear();
}

/// Average RGB of the central region of each grid cell inside rect (raster order).
List<Rgb> sampleCells(RgbaImage img, ScreenRect rect, int cols, int rows, {double inset = 0.25}) {
  final out = <Rgb>[];
  final cw = rect.w / cols, ch = rect.h / rows;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final x0 = (rect.x + c * cw + cw * inset).round();
      final x1 = math.max(x0 + 1, (rect.x + (c + 1) * cw - cw * inset).round());
      final y0 = (rect.y + r * ch + ch * inset).round();
      final y1 = math.max(y0 + 1, (rect.y + (r + 1) * ch - ch * inset).round());
      var sr = 0, sg = 0, sb = 0, cnt = 0;
      for (var y = y0; y < y1; y++) {
        if (y < 0 || y >= img.height) continue;
        for (var x = x0; x < x1; x++) {
          if (x < 0 || x >= img.width) continue;
          final i = (y * img.width + x) * 4;
          sr += img.data[i];
          sg += img.data[i + 1];
          sb += img.data[i + 2];
          cnt++;
        }
      }
      out.add(cnt > 0 ? (sr / cnt, sg / cnt, sb / cnt) : (0, 0, 0));
    }
  }
  return out;
}

class Calibration {
  double white = 200, black = 20;
}

/// Tracks black and white levels with slow decay so exposure drift is followed.
class Calibrator {
  final Calibration calib = Calibration();
  void update(List<Rgb> samples) {
    var hi = 0.0, lo = 255.0;
    for (final (r, g, b) in samples) {
      final m = math.max(r, math.max(g, b));
      if (m > hi) hi = m;
      if (m < lo) lo = m;
    }
    calib.white = math.max(hi, calib.white * 0.97);
    calib.black = math.min(lo, calib.black * 1.03 + 1);
    if (calib.white - calib.black < 40) calib.white = calib.black + 40;
  }
}

/// Classify one cell: darkness by brightest channel, hue by channel shares.
int? classifyCell(Rgb rgb, Calibration calib, {double blackFrac = 0.35, double whiteMaxShare = 0.45}) {
  final (r, g, b) = rgb;
  final m = math.max(r, math.max(g, b));
  if (m < calib.black + blackFrac * (calib.white - calib.black)) return Col.k;
  final br = math.max(0.0, r - calib.black), bg = math.max(0.0, g - calib.black), bb = math.max(0.0, b - calib.black);
  final s = br + bg + bb;
  if (s <= 0) return null;
  final nr = br / s, ng = bg / s, nb = bb / s;
  final top = math.max(nr, math.max(ng, nb));
  if (top < whiteMaxShare) return Col.w;
  if (top == nr) return Col.r;
  if (top == ng) return Col.g;
  return Col.b;
}

List<int?> classifyCells(List<Rgb> samples, Calibration calib) => [for (final s in samples) classifyCell(s, calib)];

/// Finds the transmitting screen by what makes it unique: its colours keep
/// changing (red → green → blue → white …). Lamps and windows can be brighter,
/// and mains-powered lights flicker in brightness, but their hue stays put.
///
/// For every pixel it remembers the chromaticity (r, g share of r+g+b) it last
/// had while lit, and accumulates how much that hue changes between lit
/// captures (dark captures, e.g. the black marker or Far's separators, are
/// skipped). The screen is the largest connected patch of hue activity.
class ScreenFinder {
  int _w = 0, _h = 0, frames = 0;
  late Float32List _lastR, _lastG, _act;
  double _lastT = 0;

  /// Max channel at or above which a pixel counts as lit.
  int litLevel;

  /// Smallest hue jump that counts as a colour switch. Real switches (R↔G, W↔B …)
  /// are ≥ 1; lamp colour wobble and sensor noise stay well below.
  double minJump;

  /// Accumulated colour switches needed to count a pixel as part of the screen.
  double activeLevel;

  /// Activity fades with this time constant, so Far's slow symbols still register.
  double tauMs;
  ScreenFinder({this.litLevel = 70, this.minJump = 0.3, this.activeLevel = 0.5, this.tauMs = 500});

  void reset() => _w = 0;

  ScreenRect? find(RgbaImage img, double tMs, {int minArea = 4}) {
    final w = img.width, h = img.height, n = w * h, d = img.data;
    if (w != _w || h != _h) {
      _w = w;
      _h = h;
      frames = 0;
      _lastR = Float32List(n)..fillRange(0, n, -1);
      _lastG = Float32List(n);
      _act = Float32List(n);
    }
    frames++;
    final dt = frames == 1 ? 0.0 : (tMs - _lastT).clamp(0.0, 1000.0);
    _lastT = tMs;
    final decay = math.exp(-dt / tauMs);
    for (var i = 0; i < n; i++) {
      final r = d[i * 4], g = d[i * 4 + 1], b = d[i * 4 + 2];
      final m = r > g ? (r > b ? r : b) : (g > b ? g : b);
      var a = _act[i] * decay;
      if (m >= litLevel) {
        final s = (r + g + b).toDouble();
        final cr = r / s, cg = g / s;
        if (_lastR[i] >= 0) {
          final jump = (cr - _lastR[i]).abs() + (cg - _lastG[i]).abs();
          if (jump >= minJump) a += jump;
        }
        _lastR[i] = cr;
        _lastG[i] = cg;
      }
      _act[i] = a;
    }
    if (frames < 3) return null;
    // Connected components of active pixels; keep the one with the most activity.
    final label = Int32List(n)..fillRange(0, n, -1);
    final stack = <int>[];
    ScreenRect? best;
    var bestScore = 0.0;
    var comp = 0;
    for (var start = 0; start < n; start++) {
      if (_act[start] < activeLevel || label[start] >= 0) continue;
      var minX = w, minY = h, maxX = 0, maxY = 0, area = 0;
      var score = 0.0;
      stack.add(start);
      label[start] = comp;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final x = p % w, y = p ~/ w;
        area++;
        score += _act[p];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        // 8-connected: the black marker cell can split a screen's activity diagonally.
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w || (dx == 0 && dy == 0)) continue;
            final q = yy * w + xx;
            if (label[q] >= 0 || _act[q] < activeLevel) continue;
            label[q] = comp;
            stack.add(q);
          }
        }
      }
      if (area >= minArea && score > bestScore) {
        bestScore = score;
        best = ScreenRect(minX, minY, maxX - minX + 1, maxY - minY + 1);
      }
      comp++;
    }
    return best == null ? null : _brightCore(img, best);
  }

  /// The colour-switching patch also covers whatever the screen lights up (a hand,
  /// a face, a wall), which switches colour in step with it. The screen itself is
  /// far brighter than any of that, so keep the box around pixels at least half
  /// as bright as the brightest one. A dark capture (Far's separator, a black
  /// frame) gives no answer, and the caller keeps the last box.
  ScreenRect? _brightCore(RgbaImage img, ScreenRect r) {
    final d = img.data, w = img.width;
    final x0 = math.max(0, r.x - 1), y0 = math.max(0, r.y - 1);
    final x1 = math.min(w - 1, r.x + r.w), y1 = math.min(img.height - 1, r.y + r.h);
    var peak = 0;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final i = (y * w + x) * 4;
        final m = math.max(d[i], math.max(d[i + 1], d[i + 2]));
        if (m > peak) peak = m;
      }
    }
    if (peak < litLevel) return null;
    final cut = peak ~/ 2;
    var minX = x1, minY = y1, maxX = x0, maxY = y0, n = 0;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final i = (y * w + x) * 4;
        if (math.max(d[i], math.max(d[i + 1], d[i + 2])) >= cut) {
          n++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (n == 0) return null;
    return ScreenRect(minX, minY, maxX - minX + 1, maxY - minY + 1);
  }
}

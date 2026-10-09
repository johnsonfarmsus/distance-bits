import 'vision.dart';

/// Delivery confirmation ("ack") over the return path: when a message decodes,
/// the receiver's flashlight blinks a fixed rhythm; the sender's front camera
/// (which faces the receiver, on the same side as the transmitting screen)
/// watches for it and stops sending.
///
/// Rhythm: on/off square wave, [ackHalfPeriodMs] per half, for [ackDurationMs].
/// The sender's camera runs a very short shutter, so only something as intense
/// as an LED torch seen head-on saturates; the detector then needs a compact
/// saturated white spot that keeps blinking at that rhythm, in roughly one
/// place. Lamps (steady or mains-flicker aliased to slow beats), reflections of
/// the sender's own screen, and the screen's 15–30 Hz colour changes don't
/// produce that pattern.
const int ackHalfPeriodMs = 125;
const int ackDurationMs = 3000;

class AckDetector {
  /// A pixel counts as "torch" when every channel is at least this (white, saturated).
  final int satLevel;

  /// Accepted on/off run lengths, bracketing [ackHalfPeriodMs] with room for jitter
  /// and the camera's frame quantisation.
  final double minRunMs, maxRunMs;

  /// Runs of the right length in a row needed to declare an ack (6 = 3 full blinks).
  final int runsNeeded;

  AckDetector({this.satLevel = 235, this.minRunMs = 85, this.maxRunMs = 200, this.runsNeeded = 6});

  bool _on = false;
  double _runStart = -1;
  int _goodRuns = 0;
  double? _cx, _cy; // where the spot was last seen
  bool detected = false;

  /// Feed one front-camera frame; returns true once the rhythm has been seen.
  bool add(RgbaImage img, double tMs) {
    if (detected) return true;
    final spot = _brightSpot(img);
    var on = spot != null;
    if (on && _cx != null) {
      // The torch shouldn't jump around between blinks (allow hand movement).
      final dx = (spot!.$1 - _cx!).abs() / img.width, dy = (spot.$2 - _cy!).abs() / img.height;
      if (dx > 0.15 || dy > 0.15) {
        _goodRuns = 0;
      }
    }
    if (on) {
      _cx = spot!.$1;
      _cy = spot.$2;
    }
    if (_runStart < 0) {
      _runStart = tMs;
      _on = on;
      return false;
    }
    if (on != _on) {
      final len = tMs - _runStart;
      if (len >= minRunMs && len <= maxRunMs) {
        _goodRuns++;
      } else {
        _goodRuns = 0;
      }
      _on = on;
      _runStart = tMs;
      if (_goodRuns >= runsNeeded) detected = true;
    } else if (tMs - _runStart > maxRunMs) {
      _goodRuns = 0; // stuck on or off too long: not the rhythm
    }
    return detected;
  }

  /// Centroid of saturated white pixels if they form a compact spot (not a big lit area).
  (double, double)? _brightSpot(RgbaImage img) {
    final d = img.data, w = img.width, h = img.height;
    var n = 0;
    var sx = 0.0, sy = 0.0;
    var minX = w, maxX = 0, minY = h, maxY = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        if (d[i] >= satLevel && d[i + 1] >= satLevel && d[i + 2] >= satLevel) {
          n++;
          sx += x;
          sy += y;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (n == 0) return null;
    // Compact: the saturated pixels sit in a small box (a torch, not a sunlit wall).
    final boxW = maxX - minX + 1, boxH = maxY - minY + 1;
    if (boxW > w * 0.25 || boxH > h * 0.25) return null;
    return (sx / n, sy / n);
  }
}

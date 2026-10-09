import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Exposure tuned to the sender's screen rather than the room (native side:
/// ios/Runner/AppDelegate.swift, channel distance_bits/camera).
///
/// A short fixed shutter (1/1000 s) keeps each capture inside one transmitted
/// frame, so consecutive frames don't blend; ISO is then steered so the
/// brightest cell sits just under clipping, which keeps red red and blue blue.
/// White balance is locked to daylight, close to a phone screen's white point.
class ScreenExposure {
  static const _ch = MethodChannel('distance_bits/camera');

  final String cameraId;
  bool available = false;
  double minIso = 50, maxIso = 1600, minDur = 1 / 10000, maxDur = 1 / 30;
  double iso = 200, dur = 1 / 1000;
  double _lastAdjust = -1e9;
  double _lastSeenScreen = 0;
  int _sweep = 0;
  final List<(double, double)> _recent = [];

  ScreenExposure(this.cameraId);

  String get label => available ? '1/${(1 / dur).round()} s · ISO ${iso.round()}' : 'auto';

  Future<void> start() async {
    try {
      final info = Map<String, dynamic>.from(await _ch.invokeMethod('info', {'id': cameraId}) as Map);
      minIso = (info['minISO'] as num).toDouble();
      maxIso = (info['maxISO'] as num).toDouble();
      minDur = (info['minDur'] as num).toDouble();
      maxDur = (info['maxDur'] as num).toDouble();
      dur = (1 / 1000).clamp(minDur, maxDur);
      iso = (minIso * 8).clamp(minIso, maxIso);
      available = true;
      await _apply(daylightWB: true);
    } catch (_) {
      available = false; // non-iOS or channel missing: stay on the plugin's auto exposure
    }
  }

  Future<void> _apply({bool daylightWB = false}) async {
    try {
      final r = Map<String, dynamic>.from(await _ch.invokeMethod('manual', {'id': cameraId, 'dur': dur, 'iso': iso, 'daylightWB': daylightWB}) as Map);
      iso = (r['iso'] as num).toDouble();
      dur = (r['dur'] as num).toDouble();
    } catch (_) {}
  }

  Future<void> release() async {
    if (!available) return;
    try {
      await _ch.invokeMethod('auto', {'id': cameraId});
    } catch (_) {}
  }

  /// Call once per capture. [brightest] = highest channel value among the screen's
  /// cells (null when no screen is in view); [tMs] = capture time.
  void update(double? brightest0, double tMs) {
    if (!available) return;
    // Steer by the brightest reading over the last half second: Far's black
    // separators and Mid's black half would otherwise read as "too dark" and make
    // exposure see-saw. A dark capture with the screen in view says nothing.
    double? brightest;
    if (brightest0 != null) {
      if (brightest0 >= 40) _recent.add((tMs, brightest0));
      _recent.removeWhere((e) => tMs - e.$1 > 500);
      brightest = _recent.isEmpty ? null : _recent.map((e) => e.$2).reduce(math.max);
      if (brightest == null) return;
    } else {
      _recent.clear();
    }
    if (tMs - _lastAdjust < 250) return;
    if (brightest == null) {
      // No screen in view: step through a few moderate settings (a phone screen
      // at 1/1000 s needs roughly ISO 100–800). Never climb to the maximum: that
      // lights up the room and lamps until nothing stands out.
      if (tMs - _lastSeenScreen > 1200) {
        _lastAdjust = tMs;
        _lastSeenScreen = tMs;
        final steps = [for (var k = 2.0; k <= 32; k *= 2) (minIso * k).clamp(minIso, math.min(maxIso, 1000.0)).toDouble()];
        _sweep = (_sweep + 1) % steps.length;
        iso = steps[_sweep];
        _apply();
      }
      return;
    }
    _lastSeenScreen = tMs;
    const target = 205.0;
    double factor;
    if (brightest >= 250) {
      factor = 0.5; // clipped: we can't tell how far over, so halve
    } else if (brightest < 150 || brightest > 235) {
      factor = math.min(2.0, target / math.max(brightest, 1));
    } else {
      return; // in the comfortable band
    }
    _lastAdjust = tMs;
    _recent.clear(); // judge the new setting on fresh readings
    var nIso = iso * factor;
    if (nIso < minIso) {
      // Out of ISO headroom: shorten the shutter instead.
      dur = math.max(minDur, dur * nIso / minIso);
      nIso = minIso;
    }
    iso = nIso.clamp(minIso, math.min(maxIso, 1600.0));
    _apply();
  }
}

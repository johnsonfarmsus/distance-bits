import 'dart:async';

import 'package:flutter/services.dart';

import '../core/core.dart';

/// Receiver side of delivery confirmation: blink the rear flashlight (which faces
/// the sender while listening) in the ack rhythm. See core/ack.dart.
class AckFlasher {
  static const _ch = MethodChannel('distance_bits/camera');
  static bool _running = false;

  static Future<void> blink() async {
    if (_running) return;
    _running = true;
    try {
      // Give the listening camera a moment to release the device.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final sw = Stopwatch()..start();
      var on = true;
      while (sw.elapsedMilliseconds < ackDurationMs) {
        await _ch.invokeMethod('torch', {'on': on}).catchError((_) {});
        on = !on;
        // Schedule against the clock so timer jitter doesn't accumulate.
        final next = ((sw.elapsedMilliseconds ~/ ackHalfPeriodMs) + 1) * ackHalfPeriodMs;
        await Future<void>.delayed(Duration(milliseconds: next - sw.elapsedMilliseconds));
      }
    } finally {
      await _ch.invokeMethod('torch', {'on': false}).catchError((_) {});
      _running = false;
    }
  }
}

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Field-test diagnostics written by the Listen screen when the setting is on:
/// receive logs (CSV), snapshots and frame bursts (PPM), and their info files.
/// They live in Documents so they can be copied off the phone (Files app, or
/// `xcrun devicectl device copy from`).
final RegExp _diagName = RegExp(r'^(rx-log-.*\.csv|snap-.*\.ppm|snap-info\.txt|burst-.*\.ppm|burst-info\.txt)$');

Future<List<File>> diagnosticFiles() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return [
      for (final f in dir.listSync().whereType<File>())
        if (_diagName.hasMatch(f.uri.pathSegments.last)) f,
    ];
  } catch (_) {
    return [];
  }
}

Future<int> deleteDiagnostics() async {
  var n = 0;
  for (final f in await diagnosticFiles()) {
    try {
      await f.delete();
      n++;
    } catch (_) {}
  }
  return n;
}

import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../core/core.dart';

/// Converts a camera frame into a small upright (portrait) RGBA image for the
/// vision code, rotating by the sensor orientation and subsampling as it goes.
/// Subsampling (not averaging) is fine here: cells span many pixels, and the
/// vision code averages the middle of each cell anyway.
RgbaImage? toPortraitRgba(CameraImage img, int sensorOrientation, {int targetWidth = 160}) {
  final w = img.width, h = img.height;
  // Some platform versions deliver buffers already rotated to the locked capture
  // orientation (portrait: taller than wide); only rotate a landscape buffer.
  final rot = w > h ? sensorOrientation % 360 : 0;
  final portraitW = (rot == 90 || rot == 270) ? h : w;
  final portraitH = (rot == 90 || rot == 270) ? w : h;
  final step = (portraitW / targetWidth).round().clamp(1, 16);
  final ow = portraitW ~/ step, oh = portraitH ~/ step;
  final out = Uint8List(ow * oh * 4);

  // Map an output pixel to source buffer coordinates.
  int sx(int px, int py) => switch (rot) { 90 => py, 270 => w - 1 - py, 180 => w - 1 - px, _ => px };
  int sy(int px, int py) => switch (rot) { 90 => h - 1 - px, 270 => px, 180 => h - 1 - py, _ => py };

  if (img.format.group == ImageFormatGroup.bgra8888) {
    final p = img.planes[0];
    final bytes = p.bytes, stride = p.bytesPerRow;
    var o = 0;
    for (var y = 0; y < oh; y++) {
      final py = y * step;
      for (var x = 0; x < ow; x++) {
        final px = x * step;
        final i = sy(px, py) * stride + sx(px, py) * 4;
        out[o] = bytes[i + 2];
        out[o + 1] = bytes[i + 1];
        out[o + 2] = bytes[i];
        out[o + 3] = 255;
        o += 4;
      }
    }
    return RgbaImage(out, ow, oh);
  }
  if (img.format.group == ImageFormatGroup.yuv420 && img.planes.length >= 3) {
    final yp = img.planes[0], up = img.planes[1], vp = img.planes[2];
    final uvStride = up.bytesPerRow, uvPix = up.bytesPerPixel ?? 1;
    var o = 0;
    for (var y = 0; y < oh; y++) {
      for (var x = 0; x < ow; x++) {
        final bx = sx(x * step, y * step), by = sy(x * step, y * step);
        final Y = yp.bytes[by * yp.bytesPerRow + bx];
        final uvi = (by >> 1) * uvStride + (bx >> 1) * uvPix;
        final U = up.bytes[uvi] - 128, V = vp.bytes[uvi] - 128;
        out[o] = (Y + 1.402 * V).round().clamp(0, 255);
        out[o + 1] = (Y - 0.344 * U - 0.714 * V).round().clamp(0, 255);
        out[o + 2] = (Y + 1.772 * U).round().clamp(0, 255);
        out[o + 3] = 255;
        o += 4;
      }
    }
    return RgbaImage(out, ow, oh);
  }
  return null;
}

/// Binary PPM (P6) of an RGBA image: trivial to write, readable everywhere. For diagnostics.
Uint8List toPpm(RgbaImage img) {
  final header = 'P6\n${img.width} ${img.height}\n255\n'.codeUnits;
  final out = Uint8List(header.length + img.width * img.height * 3);
  out.setAll(0, header);
  var o = header.length;
  for (var i = 0; i < img.width * img.height; i++) {
    out[o++] = img.data[i * 4];
    out[o++] = img.data[i * 4 + 1];
    out[o++] = img.data[i * 4 + 2];
  }
  return out;
}

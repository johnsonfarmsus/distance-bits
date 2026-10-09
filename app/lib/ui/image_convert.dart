import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../core/core.dart';

/// A camera frame viewed upright (portrait), read pixel by pixel without
/// copying the whole buffer. The screen is found on a small subsampled copy
/// ([coarse]); the cell colours are then read from the full-resolution buffer
/// ([sampleCells]), which is what gives range.
class CamFrame {
  final CameraImage img;
  late final int rot; // clockwise rotation applied to the buffer to make it upright
  late final int pw, ph; // upright (portrait) size in full-resolution pixels
  final int _w, _h;

  CamFrame(this.img, int sensorOrientation)
      : _w = img.width,
        _h = img.height {
    // Some platform versions deliver buffers already rotated to the locked capture
    // orientation (portrait: taller than wide); only rotate a landscape buffer.
    rot = _w > _h ? sensorOrientation % 360 : 0;
    pw = (rot == 90 || rot == 270) ? _h : _w;
    ph = (rot == 90 || rot == 270) ? _w : _h;
  }

  bool get supported =>
      img.format.group == ImageFormatGroup.bgra8888 || (img.format.group == ImageFormatGroup.yuv420 && img.planes.length >= 3);

  int _sx(int px, int py) => switch (rot) { 90 => py, 270 => _w - 1 - py, 180 => _w - 1 - px, _ => px };
  int _sy(int px, int py) => switch (rot) { 90 => _h - 1 - px, 270 => px, 180 => _h - 1 - py, _ => py };

  /// Upright pixel (px, py) as 0xRRGGBB.
  int rgbAt(int px, int py) {
    final bx = _sx(px, py), by = _sy(px, py);
    if (img.format.group == ImageFormatGroup.bgra8888) {
      final p = img.planes[0];
      final i = by * p.bytesPerRow + bx * 4;
      final b = p.bytes;
      return (b[i + 2] << 16) | (b[i + 1] << 8) | b[i];
    }
    final yp = img.planes[0], up = img.planes[1], vp = img.planes[2];
    final y = yp.bytes[by * yp.bytesPerRow + bx];
    final uvi = (by >> 1) * up.bytesPerRow + (bx >> 1) * (up.bytesPerPixel ?? 1);
    final u = up.bytes[uvi] - 128, v = vp.bytes[uvi] - 128;
    final r = (y + 1.402 * v).round().clamp(0, 255);
    final g = (y - 0.344 * u - 0.714 * v).round().clamp(0, 255);
    final bl = (y + 1.772 * u).round().clamp(0, 255);
    return (r << 16) | (g << 8) | bl;
  }

  /// Step between coarse pixels, in full-resolution pixels.
  int coarseStep(int targetWidth) => (pw / targetWidth).round().clamp(1, 32);

  /// Subsampled upright RGBA copy, about [targetWidth] wide, for finding the screen.
  RgbaImage coarse(int targetWidth) {
    final step = coarseStep(targetWidth);
    final ow = pw ~/ step, oh = ph ~/ step;
    final out = Uint8List(ow * oh * 4);
    var o = 0;
    for (var y = 0; y < oh; y++) {
      for (var x = 0; x < ow; x++) {
        final c = rgbAt(x * step, y * step);
        out[o] = (c >> 16) & 0xff;
        out[o + 1] = (c >> 8) & 0xff;
        out[o + 2] = c & 0xff;
        out[o + 3] = 255;
        o += 4;
      }
    }
    return RgbaImage(out, ow, oh);
  }

  /// Average colour of the middle of each grid cell inside [r] (full-resolution,
  /// upright coordinates), reading at most [maxPts]×[maxPts] pixels per cell.
  List<Rgb> sampleCells(ScreenRect r, int cols, int rows, {double inset = 0.25, int maxPts = 10}) {
    final out = <Rgb>[];
    final cw = r.w / cols, ch = r.h / rows;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final x0 = (r.x + col * cw + cw * inset).round(), x1 = (r.x + (col + 1) * cw - cw * inset).round();
        final y0 = (r.y + row * ch + ch * inset).round(), y1 = (r.y + (row + 1) * ch - ch * inset).round();
        final sxStep = ((x1 - x0) / maxPts).ceil().clamp(1, 1 << 20);
        final syStep = ((y1 - y0) / maxPts).ceil().clamp(1, 1 << 20);
        var sr = 0, sg = 0, sb = 0, n = 0;
        for (var y = y0; y <= y1 || n == 0; y += syStep) {
          if (y < 0 || y >= ph) {
            if (y >= ph) break;
            continue;
          }
          for (var x = x0; x <= x1; x += sxStep) {
            if (x < 0 || x >= pw) continue;
            final c = rgbAt(x, y);
            sr += (c >> 16) & 0xff;
            sg += (c >> 8) & 0xff;
            sb += c & 0xff;
            n++;
          }
          if (y > y1) break;
        }
        out.add(n > 0 ? (sr / n, sg / n, sb / n) : (0, 0, 0));
      }
    }
    return out;
  }
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

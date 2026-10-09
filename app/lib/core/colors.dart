/// Physical colors a cell can show. K (black) is reserved for the marker.
/// Plain ints (not an enum) because they sit in hot per-frame loops.
abstract final class Col {
  static const int k = 0;
  static const int w = 1;
  static const int r = 2;
  static const int g = 3;
  static const int b = 4;
}

const List<String> colorNames = ['K', 'W', 'R', 'G', 'B'];

/// sRGB for each color, as 0xRRGGBB.
const List<int> colorRgb = [0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF];

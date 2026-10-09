import 'colors.dart';

enum PresetName { near, mid, far }

enum PaletteName { wr, rgw, rgbw }

/// Allowed transmitter frame rates, in beacon order.
const List<int> fpsValues = [30, 15, 10];

class Config {
  final PresetName preset;
  final PaletteName palette;
  final int fps;
  const Config(this.preset, this.palette, this.fps);

  Config copyWith({PresetName? preset, PaletteName? palette, int? fps}) =>
      Config(preset ?? this.preset, palette ?? this.palette, fps ?? this.fps);

  @override
  bool operator ==(Object other) => other is Config && other.preset == preset && other.palette == palette && other.fps == fps;
  @override
  int get hashCode => Object.hash(preset, palette, fps);
  @override
  String toString() => '${preset.name} · ${palette.name} · $fps fps';
}

class PresetDef {
  final int cols, rows;

  /// How many frames before the marker position repeats.
  final int markerPeriod;

  /// Payload symbols per frame (0.5 for Far: every other frame is a separator).
  final double symbolsPerFrame;
  final int defaultFps;
  final PaletteName defaultPalette;

  /// Header copies sent back-to-back; the receiver merges them to fill holes.
  final int headerRepeat;

  /// Chunks per CRC-checked block.
  final int blockChunks;
  const PresetDef(this.cols, this.rows, this.markerPeriod, this.symbolsPerFrame, this.defaultFps, this.defaultPalette, this.headerRepeat, this.blockChunks);
}

const Map<PresetName, PresetDef> presets = {
  PresetName.near: PresetDef(2, 4, 8, 7, 30, PaletteName.rgbw, 2, 4),
  PresetName.mid: PresetDef(1, 2, 2, 1, 30, PaletteName.rgbw, 3, 2),
  PresetName.far: PresetDef(1, 1, 2, 0.5, 15, PaletteName.wr, 2, 2),
};

/// Payload palettes: symbol index -> physical color. Black is never a payload color.
const Map<PaletteName, List<int>> palettes = {
  PaletteName.wr: [Col.w, Col.r],
  PaletteName.rgw: [Col.r, Col.g, Col.w],
  PaletteName.rgbw: [Col.r, Col.g, Col.b, Col.w],
};

/// Symbols per packing group. Fixed at 7 so a Near frame is exactly one group.
const int groupSymbols = 7;

/// A beacon precedes every Nth epoch (the first one always).
const int defaultBeaconEvery = 4;

/// Allowed epoch lengths in chunks, coded in 2 header-flag bits.
const List<int> epochSizes = [8, 16, 32, 64];

Config defaultConfig(PresetName preset) {
  final p = presets[preset]!;
  return Config(preset, p.defaultPalette, p.defaultFps);
}

int paletteSize(PaletteName palette) => palettes[palette]!.length;

/// Physical color -> symbol index, or -1 if not in the palette.
int symbolOf(PaletteName palette, int color) => palettes[palette]!.indexOf(color);

double framePeriodMs(int fps) => 1000 / fps;

int blockBits(int blockChunks) => blockChunks * 8 + 8;

/// Epoch length for an L-byte payload: smallest size >= 1.5·L, capped at 64.
int epochChunksFor(int len) {
  for (final e in epochSizes) {
    if (e >= (len * 1.5).ceil()) return e;
  }
  return 64;
}

int epochBits(int epochChunks, int blockChunks) => (epochChunks ~/ blockChunks) * blockBits(blockChunks);

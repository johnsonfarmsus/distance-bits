/** Physical colors a cell can show. K (black) is reserved for the marker. */
export const enum Color {
  K = 0,
  W = 1,
  R = 2,
  G = 3,
  B = 4,
}

export const COLOR_NAMES = ['K', 'W', 'R', 'G', 'B'] as const;

export const COLOR_RGB: Record<Color, [number, number, number]> = {
  [Color.K]: [0, 0, 0],
  [Color.W]: [255, 255, 255],
  [Color.R]: [255, 0, 0],
  [Color.G]: [0, 255, 0],
  [Color.B]: [0, 0, 255],
};

export const COLOR_CSS: Record<Color, string> = {
  [Color.K]: '#000000',
  [Color.W]: '#ffffff',
  [Color.R]: '#ff0000',
  [Color.G]: '#00ff00',
  [Color.B]: '#0000ff',
};

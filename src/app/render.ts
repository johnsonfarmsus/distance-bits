import { COLOR_CSS, PRESETS, type Config, type Frame } from '../core';

/** Paint one frame onto a canvas. The grid fills the whole canvas — the bezel is the border. */
export function drawFrame(ctx: CanvasRenderingContext2D, frame: Frame, cfg: Config, w: number, h: number): void {
  if (frame.layout === 'blob') {
    ctx.fillStyle = COLOR_CSS[frame.cells[0]];
    ctx.fillRect(0, 0, w, h);
    return;
  }
  const p = PRESETS[cfg.preset];
  const cw = w / p.cols, ch = h / p.rows;
  for (let r = 0; r < p.rows; r++) {
    for (let c = 0; c < p.cols; c++) {
      ctx.fillStyle = COLOR_CSS[frame.cells[r * p.cols + c]];
      ctx.fillRect(Math.floor(c * cw), Math.floor(r * ch), Math.ceil(cw), Math.ceil(ch));
    }
  }
}

/**
 * Drives a transmitter at a fixed frame rate using requestAnimationFrame.
 * Frames are scheduled on a monotonic clock so a missed rAF doesn't drift the rate.
 */
export class FrameClock {
  private raf = 0;
  private nextAt = 0;
  running = false;
  constructor(private fps: number, private onFrame: (t: number) => void) {}

  start(): void {
    this.running = true;
    this.nextAt = performance.now();
    const tick = (now: number) => {
      if (!this.running) return;
      const period = 1000 / this.fps;
      if (now >= this.nextAt - 1) {
        this.onFrame(now);
        this.nextAt += period;
        if (now - this.nextAt > period * 2) this.nextAt = now + period; // fell behind; resync
      }
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  stop(): void {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }
}

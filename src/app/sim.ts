import { Color, PRESETS, Transmitter, addNoise, boxBlur, defaultConfig, encodePayload, PayloadType, type Config, type Image } from '../core';
import { RxPipeline } from './pipeline';
import { FrameClock, drawFrame } from './render';
import { configControls, describeConfig, download, h } from './ui';

/**
 * In-browser simulator: transmitter → synthetic "camera" (downscale, blur, noise,
 * color cast, capture loss) → the same receive pipeline the camera page uses.
 * Sweep "screen px" to stand in for distance.
 */
export function simPage(root: HTMLElement): () => void {
  let cfg: Config = defaultConfig('near');
  const text = h('textarea', {}) as HTMLTextAreaElement;
  text.value = 'The quick brown fox jumps over the lazy dog 0123456789';

  const txCanvas = h('canvas', { width: 128, height: 256, style: 'width:128px;height:256px' }) as HTMLCanvasElement;
  const camCanvas = h('canvas', { width: 160, height: 120, style: 'width:320px;height:240px' }) as HTMLCanvasElement;
  const txCtx = txCanvas.getContext('2d')!;
  const camCtx = camCanvas.getContext('2d', { willReadFrequently: true })!;

  const num = (label: string, value: number, min: number, max: number, step: number) => {
    const input = h('input', { type: 'number', value, min, max, step, style: 'width:90px' }) as HTMLInputElement;
    return { el: h('label', {}, label, input), get: () => Number(input.value) };
  };
  const screenPx = num('Screen width (px)', 24, 3, 120, 1);
  const blur = num('Blur radius (px)', 1, 0, 6, 1);
  const noise = num('Noise (0–60)', 8, 0, 60, 1);
  const loss = num('Capture loss %', 5, 0, 60, 1);
  const cast = num('Color cast (warm→cool)', 0, -40, 40, 5);
  const misread = num('Misread frames %', 0, 0, 50, 1);
  const controls = configControls(cfg, (c) => (cfg = c));

  const status = h('div', { class: 'card' }, 'idle');
  const result = h('div', { class: 'rx-message', style: 'display:none' });
  const stats = h('div', { class: 'stat' });
  let clock: FrameClock | null = null;
  let pipeline: RxPipeline | null = null;

  function start(): void {
    stop();
    const payload = encodePayload({ type: PayloadType.Text, text: text.value });
    const tx = new Transmitter(cfg, payload);
    const p = PRESETS[cfg.preset];
    txCanvas.width = 64 * p.cols;
    txCanvas.height = 64 * p.rows;
    const t0 = performance.now();
    let doneAt: number | null = null;
    pipeline = new RxPipeline(
      {
        onConfig: (c, s) => (status.textContent = `config ${s}: ${describeConfig(c)}`),
        onHeader: (hd) => (status.textContent = `header: msg #${hd.msgId} · ${hd.length} B · epoch ${hd.epoch}`),
        onCrcFail: () => (status.textContent = 'checksum failed: decode discarded, still listening'),
        onDone: (pl, bytes) => {
          doneAt = performance.now();
          result.style.display = '';
          result.textContent = pl.type === PayloadType.Text ? pl.text : `${bytes.length} bytes`;
          status.textContent = `DONE in ${((doneAt - t0) / 1000).toFixed(1)} s`;
          stop();
        },
      },
      { agree: 2 },
    );
    result.style.display = 'none';
    const capturesPerFrame = Math.max(1, Math.round(60 / cfg.fps));
    clock = new FrameClock(cfg.fps, (now) => {
      const frame = tx.next();
      // Misread: with the chosen probability, this transmitted frame has one lit colour
      // consistently read as another (the same in every capture, like a real misread).
      const LIT = [Color.W, Color.R, Color.G, Color.B];
      if (Math.random() * 100 < misread.get()) {
        const from = LIT[Math.floor(Math.random() * 4)];
        const to = LIT.filter((c) => c !== from)[Math.floor(Math.random() * 3)];
        pipeline!.perturb = (cells) => cells.map((c) => (c === from ? to : c));
      } else {
        pipeline!.perturb = null;
      }
      drawFrame(txCtx, frame, cfg, txCanvas.width, txCanvas.height);
      // Synthetic camera view: dark room, the screen at the requested pixel size.
      const W = camCanvas.width, H = camCanvas.height;
      const sw = screenPx.get();
      const sh = Math.round((sw * txCanvas.height) / txCanvas.width);
      camCtx.fillStyle = '#1a1816';
      camCtx.fillRect(0, 0, W, H);
      camCtx.imageSmoothingEnabled = true;
      camCtx.drawImage(txCanvas, Math.round((W - sw) / 2), Math.round((H - sh) / 2), sw, sh);
      let img: Image = camCtx.getImageData(0, 0, W, H);
      const c = cast.get();
      if (c !== 0) {
        const d = new Uint8ClampedArray(img.data);
        for (let i = 0; i < d.length; i += 4) {
          d[i] = d[i] - c;
          d[i + 2] = d[i + 2] + c;
        }
        img = { data: d, width: W, height: H };
      }
      img = boxBlur(img, blur.get());
      const base = addNoise(img, noise.get());
      camCtx.putImageData(new ImageData(new Uint8ClampedArray(base.data), W, H), 0, 0);
      const period = 1000 / cfg.fps;
      for (let i = 0; i < capturesPerFrame; i++) {
        if (Math.random() * 100 < loss.get()) continue;
        const noisy = i === 0 ? base : addNoise(img, noise.get());
        pipeline!.process(noisy, now + (i * period) / capturesPerFrame);
      }
      const s = pipeline!.receiver.stats;
      const d = pipeline!.receiver.decoder;
      const items: [string, string | number][] = [
        ['tx frames', frame.seq + 1],
        ['accepted', pipeline!.accepted],
        ['lost', s.lostFrames],
        ['headers', s.headers],
        ['chunks ok', s.chunksAdded],
        ['chunks lost', s.chunksUnknown],
        ['blocks bad', s.blocksBad],
        ['decoded', d ? `${d.progress}/${d.L}` : '—'],
        ['elapsed', `${((now - t0) / 1000).toFixed(1)} s`],
      ];
      stats.replaceChildren(...items.map(([k, v]) => h('div', {}, h('b', {}, String(v)), h('span', {}, k))));
    });
    clock.start();
    status.textContent = 'running…';
  }

  function stop(): void {
    clock?.stop();
    clock = null;
  }

  root.append(
    h('h2', {}, 'Simulator'),
    text,
    controls.el,
    h('div', { class: 'row' }, screenPx.el, blur.el, noise.el, loss.el, cast.el, misread.el),
    h('div', { class: 'row' }, h('button', { class: 'primary', click: start }, 'Run'), h('button', { click: stop }, 'Stop'), h('button', { click: () => pipeline && download('sim-log.csv', new Blob([pipeline.csv()], { type: 'text/csv' })) }, 'Download log')),
    h('div', { class: 'sim-canvases' }, h('div', {}, h('div', { class: 'muted' }, 'transmitter'), txCanvas), h('div', {}, h('div', { class: 'muted' }, 'simulated camera'), camCanvas)),
    status,
    result,
    stats,
    h('p', { class: 'muted' }, 'Screen width in pixels stands in for distance: with a phone main camera it is roughly 200 / distance-in-meters (7 cm screen, 4000 px across 70°). 24 px ≈ 8 m, 12 px ≈ 17 m, 5 px ≈ 40 m. Sweep it down until each preset breaks.'),
  );
  return () => stop();
}

import { PRESETS, Transmitter, defaultConfig, encodePayload, PayloadType, type Config, type Frame, type Payload } from '../core';
import { FrameClock, drawFrame } from './render';
import { blobOf, configControls, download, fmtBytes, fmtSeconds, h } from './ui';

const LS_KEY = 'distance-bits.send';

function loadCfg(): Config {
  try {
    const s = localStorage.getItem(LS_KEY);
    if (s) return JSON.parse(s) as Config;
  } catch {
    /* ignore */
  }
  return defaultConfig('near');
}

/** Rough wall-clock estimate for one full pass of the payload at this config (no losses). */
export function estimateSeconds(cfg: Config, bytes: number): number {
  const tx = new Transmitter(cfg, new Uint8Array(Math.max(1, bytes)), { msgId: 0 });
  const epochs = Math.ceil(bytes / tx.epochChunks);
  const beaconFrames = 64;
  const frames = epochs * tx.framesPerEpoch() + Math.ceil(epochs / tx.beaconEvery) * beaconFrames;
  return frames / cfg.fps;
}

const FLASH_OK_KEY = 'distance-bits.flash-warning-ok';

function flashWarningAccepted(): boolean {
  try {
    return localStorage.getItem(FLASH_OK_KEY) === '1';
  } catch {
    return false;
  }
}

/**
 * Photosensitivity warning shown before the first send. Full-screen flashing
 * between saturated colours and black at 3–30 Hz is a known seizure trigger.
 */
function flashWarning(onAccept: () => void): HTMLElement {
  const remember = h('input', { type: 'checkbox' }) as HTMLInputElement;
  const close = () => box.remove();
  const box = h(
    'div',
    { class: 'modal' },
    h(
      'div',
      { class: 'modal-card' },
      h('h3', {}, '⚠ Flashing lights'),
      h('p', {}, 'Sending makes this screen flash rapidly between bright colours and black. This can trigger seizures in people with photosensitive epilepsy.'),
      h('p', {}, 'Don’t use it if you or anyone who will see the screen has a history of seizures or is sensitive to flashing light. Stop at once if anyone feels unwell. Tap the screen to stop sending.'),
      h('label', { class: 'check' }, remember, 'Don’t show this again on this device'),
      h(
        'div',
        { class: 'row' },
        h('button', { click: close }, 'Cancel'),
        h('button', {
          class: 'primary',
          click: () => {
            if (remember.checked) {
              try {
                localStorage.setItem(FLASH_OK_KEY, '1');
              } catch {
                /* private mode: ask again next time */
              }
            }
            close();
            onAccept();
          },
        }, 'I understand, send'),
      ),
    ),
  );
  return box;
}

export function sendPage(root: HTMLElement): () => void {
  let cfg = loadCfg();
  const text = h('textarea', { placeholder: 'Type a message…' }) as HTMLTextAreaElement;
  text.value = localStorage.getItem(LS_KEY + '.text') ?? 'hello from distance-bits';
  const estimate = h('div', { class: 'muted' });
  const fileInfo = h('div', { class: 'muted' });
  let filePayload: Payload | null = null;

  const controls = configControls(cfg, (c) => {
    cfg = c;
    localStorage.setItem(LS_KEY, JSON.stringify(cfg));
    refresh();
  });

  const fileInput = h('input', { type: 'file', accept: 'image/*,text/*,.txt,.md' }) as HTMLInputElement;
  fileInput.addEventListener('change', async () => {
    const f = fileInput.files?.[0];
    if (!f) {
      filePayload = null;
      refresh();
      return;
    }
    if (f.type.startsWith('image/')) {
      const data = await compressImage(f, Number(imgSize.value), Number(imgQuality.value));
      filePayload = { type: PayloadType.Image, mime: 'image/jpeg', data };
    } else {
      filePayload = { type: PayloadType.File, name: f.name, data: new Uint8Array(await f.arrayBuffer()) };
    }
    refresh();
  });
  const imgSize = h('input', { type: 'number', value: 64, min: 16, max: 256, step: 8, style: 'width:80px' }) as HTMLInputElement;
  const imgQuality = h('input', { type: 'number', value: 0.4, min: 0.1, max: 0.95, step: 0.05, style: 'width:80px' }) as HTMLInputElement;
  imgSize.addEventListener('change', () => fileInput.dispatchEvent(new Event('change')));
  imgQuality.addEventListener('change', () => fileInput.dispatchEvent(new Event('change')));

  function currentPayload(): Payload {
    if (filePayload) return filePayload;
    return { type: PayloadType.Text, text: text.value || ' ' };
  }

  function refresh(): void {
    const bytes = encodePayload(currentPayload()).length;
    const secs = estimateSeconds(cfg, bytes);
    estimate.textContent = `${fmtBytes(bytes)} → about ${fmtSeconds(secs)} per pass at ${cfg.preset}/${cfg.palette}/${cfg.fps} fps (no losses; real links take longer)`;
    if (filePayload) {
      const name = filePayload.type === PayloadType.File ? filePayload.name : 'image (JPEG)';
      fileInfo.textContent = `Sending file: ${name}. Clear the file picker to send text instead.`;
    } else fileInfo.textContent = '';
    text.disabled = !!filePayload;
  }
  text.addEventListener('input', () => {
    localStorage.setItem(LS_KEY + '.text', text.value);
    refresh();
  });

  // Full-screen transmitter
  const canvas = h('canvas') as HTMLCanvasElement;
  const hud = h('div', { class: 'hud' });
  const screen = h('div', { id: 'tx-screen' }, canvas, hud);
  document.body.append(screen);
  let clock: FrameClock | null = null;
  let wakeLock: { release(): Promise<void> } | null = null;

  async function start(): Promise<void> {
    const payload = encodePayload(currentPayload());
    const tx = new Transmitter(cfg, payload);
    const ctx = canvas.getContext('2d')!;
    const w = (canvas.width = 64 * PRESETS[cfg.preset].cols);
    const hh = (canvas.height = 64 * PRESETS[cfg.preset].rows);
    screen.classList.add('on');
    try {
      await document.documentElement.requestFullscreen?.();
    } catch {
      /* iOS Safari: no fullscreen API; the fixed overlay is enough */
    }
    try {
      wakeLock = await (navigator as Navigator & { wakeLock?: { request(t: string): Promise<{ release(): Promise<void> }> } }).wakeLock?.request('screen') ?? null;
    } catch {
      wakeLock = null;
    }
    let frames = 0;
    let last: Frame | null = null;
    const t0 = performance.now();
    clock = new FrameClock(cfg.fps, () => {
      last = tx.next();
      drawFrame(ctx, last, cfg, w, hh);
      frames++;
      if (frames % 15 === 0) {
        const s = ((performance.now() - t0) / 1000).toFixed(0);
        hud.textContent = `sending · ${cfg.preset}/${cfg.palette}/${cfg.fps}fps · epoch ${last.epoch} · ${last.segment} · ${s}s · tap to stop`;
      }
    });
    clock.start();
  }

  function stop(): void {
    clock?.stop();
    clock = null;
    screen.classList.remove('on');
    wakeLock?.release().catch(() => {});
    wakeLock = null;
    if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
  }
  screen.addEventListener('click', stop);

  const sendBtn = h('button', {
    class: 'primary',
    click: () => (flashWarningAccepted() ? start() : document.body.append(flashWarning(() => void start()))),
  }, 'Send (full screen)');

  root.append(
    h('h2', {}, 'Message'),
    text,
    h('div', { class: 'row' }, h('label', {}, 'Or a file / image', fileInput), h('label', {}, 'Image px', imgSize), h('label', {}, 'JPEG quality', imgQuality)),
    fileInfo,
    h('h2', {}, 'Link settings'),
    controls.el,
    estimate,
    h('div', { class: 'row' }, sendBtn, h('button', { click: () => download('payload.bin', blobOf(encodePayload(currentPayload()))) }, 'Download payload bytes')),
    h('p', { class: 'muted' }, 'Turn screen brightness all the way up, disable auto-lock, and hold the phone upright with the screen toward the receiver. Tap the screen to stop. The sender never stops on its own (there is no uplink in the web version yet).'),
  );
  refresh();
  return () => {
    stop();
    screen.remove();
  };
}

async function compressImage(file: File, size: number, quality: number): Promise<Uint8Array> {
  const bmp = await createImageBitmap(file);
  const scale = Math.min(1, size / Math.max(bmp.width, bmp.height));
  const w = Math.max(1, Math.round(bmp.width * scale));
  const hgt = Math.max(1, Math.round(bmp.height * scale));
  const c = document.createElement('canvas');
  c.width = w;
  c.height = hgt;
  c.getContext('2d')!.drawImage(bmp, 0, 0, w, hgt);
  const blob = await new Promise<Blob | null>((res) => c.toBlob(res, 'image/jpeg', quality));
  return new Uint8Array(await blob!.arrayBuffer());
}

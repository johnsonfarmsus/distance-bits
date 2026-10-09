import { COLOR_CSS, PayloadType, defaultConfig, type Config, type Payload } from '../core';
import { Camera } from './camera';
import { RxPipeline } from './pipeline';
import { blobOf, configControls, describeConfig, download, h, select } from './ui';

export function receivePage(root: HTMLElement): () => void {
  const video = h('video', { autoplay: true, playsinline: true }) as HTMLVideoElement;
  const overlay = h('canvas', { class: 'overlay' }) as HTMLCanvasElement;
  const view = h('div', { class: 'rx-view' }, video, overlay);
  const work = document.createElement('canvas');
  const wctx = work.getContext('2d', { willReadFrequently: true })!;
  const camera = new Camera(video);

  const status = h('div', { class: 'card' }, 'Camera off');
  const progress = h('progress', { value: 0, max: 1 }) as HTMLProgressElement;
  const message = h('div', { class: 'rx-message', style: 'display:none' });
  const cellsView = h('div', { class: 'cells' });
  const statGrid = h('div', { class: 'stat' });

  let pipeline: RxPipeline | null = null;
  let running = false;
  let manual: Config | null = null;
  let agree = 2;
  let sampleWidth = 240;
  let lastUi = 0;

  const modeSel = select<'auto' | 'manual'>('Config', [{ value: 'auto', label: 'Auto-detect from sender' }, { value: 'manual', label: 'Manual (must match sender)' }], 'auto', (v) => {
    manual = v === 'manual' ? manualControls.get() : null;
    manualControls.el.style.display = v === 'manual' ? '' : 'none';
    if (running) restartPipeline();
  });
  const manualControls = configControls(defaultConfig('near'), (c) => {
    manual = c;
    if (running) restartPipeline();
  });
  manualControls.el.style.display = 'none';
  const agreeSel = select<number>('Accept after', [{ value: 1, label: '1 capture (fast, noisier)' }, { value: 2, label: '2 agreeing captures' }, { value: 3, label: '3 agreeing captures' }], 2, (v) => {
    agree = v;
    if (running) restartPipeline();
  });
  const widthSel = select<number>('Analysis width', [{ value: 160, label: '160 px (fast)' }, { value: 240, label: '240 px' }, { value: 320, label: '320 px' }, { value: 480, label: '480 px (slow)' }], 240, (v) => (sampleWidth = v));
  const fpsSel = select<number>('Camera fps', [{ value: 60, label: '60 (wanted)' }, { value: 30, label: '30' }], 60, () => {});

  function restartPipeline(): void {
    pipeline = new RxPipeline(
      {
        onConfig: (cfg, source) => setStatus(`Config ${source}: ${describeConfig(cfg)}`),
        onHeader: (hd) => setStatus(`Locked: message #${hd.msgId}, ${hd.length} bytes, epoch ${hd.epoch}`),
        onProgress: (solved, total) => {
          progress.value = solved / total;
        },
        onDone: (payload, bytes, hd) => showDone(payload, bytes, hd.msgId),
        onCrcFail: (_bytes, hd) => setStatus(`Message #${hd.msgId}: checksum failed (a chunk was misread). Discarded, still listening…`),
      },
      { agree, manualConfig: manual ?? undefined },
    );
    message.style.display = 'none';
    progress.value = 0;
  }

  function setStatus(s: string): void {
    status.textContent = s;
  }

  function showDone(payload: Payload, bytes: Uint8Array, msgId: number): void {
    message.style.display = '';
    message.replaceChildren();
    if (payload.type === PayloadType.Text) {
      message.append(h('div', {}, payload.text));
    } else if (payload.type === PayloadType.Image) {
      const url = URL.createObjectURL(blobOf(payload.data, payload.mime));
      message.append(h('img', { src: url, alt: 'received image' }));
    } else {
      message.append(h('div', {}, `File: ${payload.name} (${payload.data.length} bytes)`));
      message.append(h('button', { click: () => download(payload.name, blobOf(payload.data)) }, 'Download'));
    }
    if (navigator.vibrate) navigator.vibrate([300]);
    setStatus(`DONE · message #${msgId} · ${bytes.length} bytes`);
  }

  async function start(): Promise<void> {
    restartPipeline();
    try {
      await camera.start({ facing: 'environment', width: 1280, fps: fpsSel.get() }, onCapture);
    } catch (e) {
      setStatus(`Camera error: ${(e as Error).message}. Needs HTTPS and camera permission.`);
      return;
    }
    running = true;
    const locked = await camera.tryLock();
    const st = camera.actualSettings();
    setStatus(`Camera ${st?.width}×${st?.height} @ ${st?.frameRate ?? '?'} fps${locked.length ? ` · locked ${locked.join(', ')}` : ' · no manual controls (iOS)'} · waiting for a sender`);
    startBtn.disabled = true;
    stopBtn.disabled = false;
  }

  function stop(): void {
    camera.stop();
    running = false;
    startBtn.disabled = false;
    stopBtn.disabled = true;
    setStatus('Camera off');
  }

  function onCapture(t: number): void {
    if (!pipeline || !running || video.videoWidth === 0) return;
    const scale = sampleWidth / video.videoWidth;
    const w = sampleWidth, hh = Math.round(video.videoHeight * scale);
    if (work.width !== w || work.height !== hh) {
      work.width = w;
      work.height = hh;
    }
    wctx.drawImage(video, 0, 0, w, hh);
    const img = wctx.getImageData(0, 0, w, hh);
    const rec = pipeline.process(img, t);
    if (t - lastUi > 100) {
      lastUi = t;
      drawOverlay(rec.rect, w, hh);
      updateStats();
    }
  }

  function drawOverlay(rect: { x: number; y: number; w: number; h: number } | null, w: number, hh: number): void {
    if (overlay.width !== w || overlay.height !== hh) {
      overlay.width = w;
      overlay.height = hh;
    }
    const ctx = overlay.getContext('2d')!;
    ctx.clearRect(0, 0, w, hh);
    if (!rect || !pipeline) return;
    ctx.strokeStyle = '#ffcc33';
    ctx.lineWidth = 2;
    ctx.strokeRect(rect.x, rect.y, rect.w, rect.h);
    const { cols, rows } = pipeline.receiver.samplingGrid();
    cellsView.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
    cellsView.replaceChildren(
      ...pipeline.lastCells.map((c) => h('i', { style: `background:${c === null ? '#555' : COLOR_CSS[c]}` })),
    );
    void rows;
  }

  function updateStats(): void {
    if (!pipeline) return;
    const s = pipeline.receiver.stats;
    const d = pipeline.receiver.decoder;
    const items: [string, string | number][] = [
      ['captures', pipeline.captures],
      ['accepted', pipeline.accepted],
      ['parsed', s.parsed],
      ['lost frames', s.lostFrames],
      ['headers', s.headers],
      ['epochs', s.epochs],
      ['chunks ok', s.chunksAdded],
      ['chunks lost', s.chunksUnknown],
      ['blocks bad', s.blocksBad],
      ['decoded', d ? `${d.progress}/${d.L}` : '—'],
      ['calib', `${Math.round(pipeline.calibrator.calib.black)}–${Math.round(pipeline.calibrator.calib.white)}`],
    ];
    statGrid.replaceChildren(...items.map(([k, v]) => h('div', {}, h('b', {}, String(v)), h('span', {}, k))));
  }

  const startBtn = h('button', { class: 'primary', click: () => start() }, 'Start camera');
  const stopBtn = h('button', { click: () => stop(), disabled: true }, 'Stop');
  const csvBtn = h('button', { click: () => pipeline && download(`rx-log-${Date.now()}.csv`, new Blob([pipeline.csv()], { type: 'text/csv' })) }, 'Download log (CSV)');
  const resetBtn = h('button', { click: () => running && restartPipeline() }, 'Reset decoder');

  root.append(
    view,
    status,
    progress,
    message,
    h('div', { class: 'row' }, startBtn, stopBtn, resetBtn, csvBtn),
    h('div', { class: 'row' }, h('label', {}, 'Live cells', cellsView)),
    statGrid,
    h('h2', {}, 'Settings'),
    h('div', { class: 'row' }, modeSel.el, agreeSel.el, widthSel.el, fpsSel.el),
    manualControls.el,
    h('p', { class: 'muted' }, 'The sender’s screen flashes rapidly. If you are sensitive to flashing light, look at this screen rather than the sender’s.'),
    h('p', { class: 'muted' }, 'Point the rear camera at the sender so its screen is the brightest thing in view. The yellow box shows where the decoder thinks the screen is. Auto-detect needs a few seconds of clean frames; if it keeps flipping, pick Manual and match the sender.'),
  );
  return () => stop();
}

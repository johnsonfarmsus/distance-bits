import {
  Calibrator,
  FrameAcceptor,
  Receiver,
  RectTracker,
  classifyCells,
  findScreen,
  sampleCells,
  type Color,
  type Config,
  type FrameLog,
  type Header,
  type Image,
  type Payload,
  type RGB,
  type Rect,
} from '../core';

export interface PipelineEvents {
  onConfig?(cfg: Config, source: string): void;
  onHeader?(h: Header): void;
  onProgress?(solved: number, total: number, received: number): void;
  onDone?(payload: Payload, bytes: Uint8Array, h: Header): void;
  onCrcFail?(bytes: Uint8Array, h: Header): void;
}

export interface CaptureRecord {
  t: number;
  rect: Rect | null;
  cells: (Color | null)[] | null;
  accepted: boolean;
  frame?: FrameLog;
}

export interface PipelineOptions {
  agree: number;
  manualConfig?: Config;
}

/**
 * The receive pipeline from pixels to decoded message. Shared by the camera
 * receiver and the simulator so they behave identically.
 */
export class RxPipeline {
  receiver: Receiver;
  tracker = new RectTracker();
  calibrator = new Calibrator();
  acceptor: FrameAcceptor;
  lastRect: Rect | null = null;
  lastSamples: RGB[] = [];
  lastCells: (Color | null)[] = [];
  captures = 0;
  accepted = 0;
  log: CaptureRecord[] = [];
  keepLog = true;
  private pendingFrame: FrameLog | null = null;

  constructor(events: PipelineEvents, opts: PipelineOptions) {
    this.acceptor = new FrameAcceptor(opts.agree);
    this.receiver = new Receiver(
      {
        onConfig: (c, s) => {
          this.acceptor.reset();
          events.onConfig?.(c, s);
        },
        onHeader: (h) => events.onHeader?.(h),
        onProgress: (a, b, c) => events.onProgress?.(a, b, c),
        onDone: (p, b, h) => events.onDone?.(p, b, h),
        onCrcFail: (b, h) => events.onCrcFail?.(b, h),
        onFrame: (f) => (this.pendingFrame = f),
      },
      opts.manualConfig,
    );
  }

  /** Feed one captured image (small, ≈160–320 px wide). Returns the per-capture record. */
  process(img: Image, t: number): CaptureRecord {
    this.captures++;
    const found = findScreen(img);
    const rect = this.tracker.update(found, t);
    this.lastRect = rect;
    const rec: CaptureRecord = { t, rect, cells: null, accepted: false };
    if (rect) {
      const { cols, rows } = this.receiver.samplingGrid();
      const samples = sampleCells(img, rect, cols, rows);
      this.calibrator.update(samples);
      const cells = classifyCells(samples, this.calibrator.calib);
      this.lastSamples = samples;
      this.lastCells = cells;
      rec.cells = cells;
      const obs = this.acceptor.offer(cells, t);
      if (obs) {
        this.accepted++;
        rec.accepted = true;
        this.pendingFrame = null;
        this.receiver.observe(obs);
        if (this.pendingFrame) rec.frame = this.pendingFrame;
      }
    } else {
      // No screen visible: a black separator or nothing in view. Offer an
      // all-black observation so Far/beacon separators are still counted.
      const { cols, rows } = this.receiver.samplingGrid();
      const cells = new Array<Color | null>(cols * rows).fill(0 as Color);
      rec.cells = cells;
      const obs = this.acceptor.offer(cells, t);
      if (obs) {
        this.accepted++;
        rec.accepted = true;
        this.pendingFrame = null;
        this.receiver.observe(obs);
        if (this.pendingFrame) rec.frame = this.pendingFrame;
      }
    }
    if (this.keepLog) {
      this.log.push(rec);
      if (this.log.length > 20000) this.log.splice(0, 5000);
    }
    return rec;
  }

  csv(): string {
    const lines = ['t_ms,rect,cells,accepted,seq,marker,lost,kind,symbols,state'];
    for (const r of this.log) {
      const rect = r.rect ? `${r.rect.x}:${r.rect.y}:${r.rect.w}:${r.rect.h}` : '';
      const cells = r.cells ? r.cells.map((c) => (c === null ? '?' : 'KWRGB'[c])).join('') : '';
      const f = r.frame;
      lines.push(
        [r.t.toFixed(1), rect, cells, r.accepted ? 1 : 0, f?.seq ?? '', f?.marker ?? '', f?.lost ?? '', f?.kind ?? '', f?.symbols ?? '', f?.state ?? ''].join(','),
      );
    }
    return lines.join('\n');
  }
}

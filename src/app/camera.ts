/** Rear-camera capture with a per-frame callback (requestVideoFrameCallback where available). */
export interface CameraOptions {
  facing: 'environment' | 'user';
  width: number;
  fps: number;
}

export class Camera {
  video: HTMLVideoElement;
  stream: MediaStream | null = null;
  private stop_ = false;
  private onFrame: ((t: number) => void) | null = null;

  constructor(video: HTMLVideoElement) {
    this.video = video;
    video.setAttribute('playsinline', '');
    video.muted = true;
  }

  async start(opts: CameraOptions, onFrame: (t: number) => void): Promise<void> {
    this.stop();
    this.stop_ = false;
    this.onFrame = onFrame;
    const constraints: MediaStreamConstraints = {
      audio: false,
      video: {
        facingMode: { ideal: opts.facing },
        width: { ideal: opts.width },
        frameRate: { ideal: opts.fps },
      },
    };
    this.stream = await navigator.mediaDevices.getUserMedia(constraints);
    this.video.srcObject = this.stream;
    await this.video.play();
    this.loop();
  }

  /** Try to lock exposure/white balance/focus where the browser allows it (Android Chrome mostly). */
  async tryLock(): Promise<string[]> {
    const track = this.stream?.getVideoTracks()[0];
    if (!track) return [];
    const caps = (track.getCapabilities?.() ?? {}) as Record<string, unknown>;
    const applied: string[] = [];
    const advanced: Record<string, unknown>[] = [];
    if (Array.isArray(caps.exposureMode) && (caps.exposureMode as string[]).includes('manual')) advanced.push({ exposureMode: 'manual' });
    if (Array.isArray(caps.whiteBalanceMode) && (caps.whiteBalanceMode as string[]).includes('manual')) advanced.push({ whiteBalanceMode: 'manual' });
    if (Array.isArray(caps.focusMode) && (caps.focusMode as string[]).includes('manual')) advanced.push({ focusMode: 'manual' });
    for (const a of advanced) {
      try {
        await track.applyConstraints({ advanced: [a] } as MediaTrackConstraints);
        applied.push(Object.keys(a)[0]);
      } catch {
        /* not supported */
      }
    }
    return applied;
  }

  actualSettings(): MediaTrackSettings | null {
    return this.stream?.getVideoTracks()[0]?.getSettings() ?? null;
  }

  private loop(): void {
    const v = this.video as HTMLVideoElement & { requestVideoFrameCallback?: (cb: (now: number) => void) => number };
    if (typeof v.requestVideoFrameCallback === 'function') {
      const tick = (now: number) => {
        if (this.stop_) return;
        this.onFrame?.(now);
        v.requestVideoFrameCallback!(tick);
      };
      v.requestVideoFrameCallback(tick);
    } else {
      const tick = (now: number) => {
        if (this.stop_) return;
        this.onFrame?.(now);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }
  }

  stop(): void {
    this.stop_ = true;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
  }
}

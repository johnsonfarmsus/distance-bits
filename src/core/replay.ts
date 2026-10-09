// Replay a receiver CSV log (classified cells per capture) through FrameAcceptor + Receiver.
import { readFileSync } from 'node:fs';
import { FrameAcceptor, Receiver } from './receiver';
import type { Color } from './colors';

export function replay(path: string, opts: { agree?: number; verbose?: boolean } = {}) {
  const lines = readFileSync(path, 'utf8').trim().split('\n').slice(1);
  const events: string[] = [];
  let done: string | null = null;
  const rx = new Receiver({
    onConfig: (c, s) => events.push(`config ${s} ${c.preset}/${c.palette}/${c.fps}`),
    onHeader: (h) => events.push(`header msg${h.msgId} len${h.length} ep${h.epoch} E${h.epochChunks}`),
    onDone: (p) => { done = p.type === 0 ? p.text : 'non-text'; events.push(`DONE ${done}`); },
    onCrcFail: () => events.push('crcfail'),
  });
  const acc = new FrameAcceptor(opts.agree ?? 2);
  for (const line of lines) {
    const f = line.split(',');
    const t = Number(f[0]);
    const cells = f[2];
    if (!cells) continue;
    const cs = [...cells].map((c) => (c === '?' ? null : ('KWRGB'.indexOf(c) as Color)));
    const obs = acc.offer(cs, t);
    if (obs) rx.observe(obs);
  }
  return { done, events, stats: rx.stats, progress: rx.decoder ? `${rx.decoder.progress}/${rx.decoder.L}` : '-' };
}

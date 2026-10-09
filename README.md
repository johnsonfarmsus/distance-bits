# distance-bits

Phone-to-phone text over light. One phone's screen strobes a color grid; the other
phone's rear camera reads it. A fountain code means there is no retransmit: the
sender loops until the receiver has enough. Range is a first-class setting — the
grid gets coarser (and slower) as the distance goes up.

`DESIGN.md` is the design writeup. `PROTOCOL.md` is what the code actually does
where the two differ.

## Layout

```
src/core/      the protocol, pure TypeScript, no browser APIs (unit-tested)
  fountain.ts    systematic LT fountain code (peeling + GF(2) elimination fallback)
  packing.ts     7 symbols of k colors -> 7 / 11 / 14 bits
  framing.ts     beacon + header encode/decode
  transmitter.ts payload -> endless frame sequence with the walking black marker
  receiver.ts    frames -> symbols -> chunks -> decoder; auto-detects the sender's config
  vision.ts      find the screen, sample cells, classify colors, simulator helpers
src/app/       the web app (Vite, vanilla TS)
  send.ts        full-screen transmitter
  receive.ts     camera receiver with live overlay, stats and CSV log
  sim.ts         in-browser simulator: sweep "screen px" to stand in for distance; inject misreads
  pipeline.ts    pixels -> decoder, shared by receive and sim
```

## Run it

```
npm install
npm run dev        # https://<your-mac-ip>:5173  (self-signed cert; accept it once on each phone)
npm test           # unit tests
npm run build      # production build in dist/
```

Camera access needs HTTPS, which is why the dev server uses a self-signed
certificate. On each iPhone, open the `https://192.168.x.x:5173` address the dev
server prints, accept the certificate warning, then allow camera access.

For a hosted copy: push to GitHub, enable Pages (source: GitHub Actions), and the
workflow in `.github/workflows/deploy.yml` builds and publishes on every push to
`main`. Add it to the home screen on the phones to get a full-screen PWA.

## First test with two iPhones

1. Phone A: open **Send**, type a short message, leave the preset on **Near**, tap
   *Send*. Brightness all the way up, auto-lock off. Hold it upright, screen toward B.
2. Phone B: open **Receive**, *Start camera*, aim so A's screen is the brightest thing
   in view. The yellow box should hug the screen; the "Live cells" swatch should look
   like A's grid.
3. Within a few seconds B should show `Config auto: near · rgbw · 30 fps`, then
   `Locked: message #…`, then the message.
4. Tap A's screen to stop (there is no return channel in the web version, so the sender
   never stops on its own).
5. *Download log (CSV)* on B after each run. That file is the experiment. Its `rgb`
   column holds the raw colour of every cell in every capture, so the colour
   classifier can be tuned from real data afterwards.

If auto-detect keeps flipping, switch B to **Manual** and match A's settings.

Then start walking back. Sweep the presets and the blue toggle at each distance
and keep the CSVs.

## What's here and what isn't

The sender shows a flashing-light (photosensitivity) warning before the first send.

Working: all three presets, all three palettes (blue on/off is a setting on both the
sender and, via auto-detect or manual, the receiver), fountain-coded text, small files
and JPEG-compressed images, per-frame CSV logging, the simulator.

Not yet: the flash return channel (iOS Safari can't drive the torch; needs a native
shell), exposure lock on iOS, 180° orientation recovery (hold both phones upright),
and the corner-finder fallback for bright backgrounds.

## Known limits

The Far preset is slow by design — about 7.5 bit/s in mono at 15 fps. "hi" takes
about 30 s on a clean link; longer messages take minutes. The simulator will show you exactly how long before you go
outside.

Screen detection is "largest bright blob". Against a bright sky or a lit wall it will
grab the wrong thing. Dusk is your friend.

## Headless check

`npm run build && npm run preview -- --port 4173` in one terminal, then
`npm run smoke` in another runs the simulator through real Chromium for the Near and
Mid presets plus a 10% misread run (`SMOKE_FAR=1` adds Far, about 30 s). Needs
`npx playwright install chromium` once.

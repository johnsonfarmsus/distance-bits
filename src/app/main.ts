import { h } from './ui';
import { sendPage } from './send';
import { receivePage } from './receive';
import { simPage } from './sim';

type Route = 'send' | 'receive' | 'sim' | 'about';
const routes: Record<Route, string> = { send: 'Send', receive: 'Receive', sim: 'Simulator', about: 'About' };

const app = document.getElementById('app')!;
let teardown: (() => void) | null = null;

function render(): void {
  teardown?.();
  teardown = null;
  const route = ((location.hash.replace('#', '') || 'send') as Route) in routes ? ((location.hash.replace('#', '') || 'send') as Route) : 'send';
  app.replaceChildren();
  app.append(
    h('h1', {}, 'distance-bits', h('small', {}, 'text over light')),
    h('nav', {}, ...(Object.keys(routes) as Route[]).map((r) => h('a', { href: `#${r}`, class: r === route ? 'active' : '' }, routes[r]))),
  );
  const page = h('div');
  app.append(page);
  if (route === 'send') teardown = sendPage(page);
  else if (route === 'receive') teardown = receivePage(page);
  else if (route === 'sim') teardown = simPage(page);
  else aboutPage(page);
}

function aboutPage(root: HTMLElement): void {
  root.append(
    h('div', { class: 'card' },
      h('p', {}, 'Two phones, no radios. One screen strobes a color grid; the other phone’s camera reads it. A fountain code means there is no retransmit — the sender loops until the receiver has enough.'),
      h('p', {}, 'Web version limits: the receiver can’t lock exposure or control the flash on iOS, so there is no return channel yet — stop the sender by hand once the receiver shows DONE.'),
      h('p', {}, 'Quick start: on the sender, type a message, pick a range preset, tap Send. On the receiver, open Receive, start the camera, aim at the sender’s screen. Download the CSV log after each test run.'),
      h('p', { class: 'muted' }, `Build ${__BUILD_TIME__}`),
    ),
  );
}

window.addEventListener('hashchange', render);
render();

if ('serviceWorker' in navigator && import.meta.env.PROD) {
  navigator.serviceWorker.register(`${import.meta.env.BASE_URL}sw.js`).catch(() => {});
}

// Evenda brand kit generator: logo files, lockups, Play feature graphic and
// shirt mockups, all from the app icon's geometry (tool/icon/evenda_icon.mjs).
//
// Usage: node tool/brand/brand.mjs <work-dir>
// Writes SVGs to docs/brand/, and HTML pages to <work-dir> that are rendered to
// PNG with headless Chrome (see render list printed at the end).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

export const C = {
  forest: '#1B3B22',
  bronze: '#996633',
  bronzeLight: '#C9A27A', // bronze on dark grounds
  cream: '#FDFCF7',
  ink: '#171A18',
  sand: '#E8DFCC',
};

// Icon geometry on a 1024 canvas, centre 512: disc R 270, counter 134,
// crossbar 62, aperture 62 starting 44 left of centre. Bronze below the aperture.
let uid = 0;
// Drawn as two plain paths (no masks), so printers and design apps read it as is.
// Disc R 270 in a 540 box: forest above the aperture's lower edge (y = 93 from
// centre) with the counter and aperture cut out; bronze below it.
const R = 270, sx = Math.sqrt(R * R - 93 * 93), rx = Math.sqrt(R * R - 31 * 31);
const f = (n) => +(n + 270).toFixed(2);
const TOP = `M ${f(-sx)} ${f(93)} A ${R} ${R} 0 1 1 ${f(rx)} ${f(31)} L ${f(-13)} ${f(31)} A 31 31 0 0 0 ${f(-13)} ${f(93)} Z ` +
  `M ${f(-134)} ${f(-31)} A 134 134 0 0 1 ${f(134)} ${f(-31)} Z`;
const LOW = `M ${f(-sx)} ${f(93)} L ${f(sx)} ${f(93)} A ${R} ${R} 0 0 1 ${f(-sx)} ${f(93)} Z`;
export function mark({ top = C.forest, low = C.bronze, x = 0, y = 0, size = 540 } = {}) {
  return `<g transform="translate(${x} ${y}) scale(${size / 540})"><path d="${TOP}" fill="${top}" fill-rule="evenodd"/><path d="${LOW}" fill="${low}"/></g>`;
}

const figtree = readFileSync(new URL('../../assets/fonts/Figtree.ttf', import.meta.url)).toString('base64');
const fraunces = readFileSync(new URL('../../assets/fonts/Fraunces.ttf', import.meta.url)).toString('base64');
export const fonts = `@font-face{font-family:EvFig;src:url(data:font/ttf;base64,${figtree}) format('truetype');}
@font-face{font-family:EvFra;src:url(data:font/ttf;base64,${fraunces}) format('truetype');}`;

/// Mark + "evenda" wordmark (Figtree 680, as in the app). Height = mark size.
export function lockup({ ink = C.forest, top, low, x = 0, y = 0, size = 100 } = {}) {
  return `${mark({ top: top ?? ink, low: low ?? C.bronze, x, y, size })}
    <text x="${x + size * 1.3}" y="${y + size * 0.76}" font-family="EvFig, Figtree, sans-serif" font-size="${size * 0.82}"
      style="font-variation-settings:'wght' 680" font-weight="680" letter-spacing="${size * 0.004}" fill="${ink}">evenda</text>`;
}
export const lockupWidth = (size) => size * 1.3 + size * 0.82 * 3.3; // measured: Figtree 680 "evenda" ≈ 3.3 em

const svg = (w, h, inner, bg) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><defs><style>${fonts}</style></defs>${bg ? `<rect width="${w}" height="${h}" fill="${bg}"/>` : ''}${inner}</svg>`;
const plainSvg = (w, h, inner) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}">${inner}</svg>\n`;
const page = (body) => `<html><head><meta charset="utf-8"></head><body style="margin:0;background:transparent">${body}</body></html>`;

// --- Shirts ----------------------------------------------------------------
// A flat tee, front or back (back: higher neckline). 600 x 640 units.
export function shirt({ color, view = 'front', print = '', seam = 'rgba(0,0,0,.10)', shade = 'rgba(0,0,0,.06)' }) {
  const id = `sh${++uid}`;
  const neck = view === 'front' ? 'C 245 92, 355 92, 390 40' : 'C 250 62, 350 62, 390 40';
  const body = `M 210 40 ${neck} L 472 64 L 592 152 L 546 250 L 478 222 L 480 602 Q 300 618 120 602 L 122 222 L 54 250 L 8 152 L 128 64 Z`;
  return `<defs>
      <clipPath id="${id}"><path d="${body}"/></clipPath>
      <linearGradient id="${id}g" x1="0" x2="1"><stop offset="0" stop-color="#000" stop-opacity=".07"/><stop offset=".22" stop-color="#000" stop-opacity="0"/>
        <stop offset=".78" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".08"/></linearGradient>
    </defs>
    <path d="${body}" fill="${color}"/>
    <g clip-path="url(#${id})">
      <rect width="600" height="640" fill="url(#${id}g)"/>
      <path d="M 122 222 Q 160 400 150 600 M 478 222 Q 440 400 450 600" stroke="${shade}" stroke-width="10" fill="none" opacity=".6"/>
      ${print}
    </g>
    <path d="M 210 40 ${neck}" fill="none" stroke="${seam}" stroke-width="9"/>
    <path d="M 128 64 L 122 222 M 472 64 L 478 222" stroke="${seam}" stroke-width="2.5" fill="none"/>
    <path d="M 54 250 L 122 222 M 546 250 L 478 222" stroke="${seam}" stroke-width="2.5" fill="none" opacity=".7"/>
    <path d="M 120 586 Q 300 602 480 586" stroke="${seam}" stroke-width="2" fill="none"/>`;
}

const tag = (text, x, y, size, fill, weight = 600, family = 'EvFig, Figtree, sans-serif', anchor = 'middle', spacing = 0) =>
  `<text x="${x}" y="${y}" text-anchor="${anchor}" font-family="${family}" font-size="${size}" font-weight="${weight}" style="font-variation-settings:'wght' ${weight}" letter-spacing="${spacing}" fill="${fill}">${text}</text>`;

// --- App on a shirt ------------------------------------------------------------
// The Play Store address is fixed by the application ID; the QR pattern is
// stored as data (tool/brand/qr-play-store.json), generated once.
const QR = JSON.parse(readFileSync(new URL('./qr-play-store.json', import.meta.url), 'utf8'));
export function qr({ x, y, size, fg = C.forest, bg = '#FFFFFF' }) {
  const n = QR.size, quiet = 4, cell = size / (n + quiet * 2);
  let d = '';
  QR.rows.forEach((row, r) => { for (let c = 0; c < n; c++) if (row[c] === '1') d += `M${(c + quiet) * cell} ${(r + quiet) * cell}h${cell}v${cell}h-${cell}z`; });
  return `<g transform="translate(${x} ${y})"><rect width="${size}" height="${size}" rx="${cell * 1.5}" fill="${bg}"/><path d="${d}" fill="${fg}" shape-rendering="crispEdges"/></g>`;
}

const t = (x, y, text, size, fill, weight = 500, family = 'EvFig, Figtree, sans-serif', anchor = 'start') =>
  `<text x="${x}" y="${y}" text-anchor="${anchor}" font-family="${family}" font-size="${size}" font-weight="${weight}" style="font-variation-settings:'wght' ${weight}" fill="${fill}">${text}</text>`;

// Simple stock glyphs for listing thumbnails (forest on sand).
const glyph = {
  chair: (x, y) => `<path d="M${x + 15} ${y + 10}v26M${x + 31} ${y + 10}v26M${x + 15} ${y + 24}h16M${x + 15} ${y + 10}h16" stroke="${C.forest}" stroke-width="3.2" stroke-linecap="round" fill="none"/>`,
  tent: (x, y) => `<path d="M${x + 8} ${y + 36}L${x + 23} ${y + 10}L${x + 38} ${y + 36}ZM${x + 23} ${y + 22}v14" stroke="${C.forest}" stroke-width="3.2" stroke-linejoin="round" fill="none"/>`,
  light: (x, y) => `<circle cx="${x + 23}" cy="${y + 20}" r="9" stroke="${C.forest}" stroke-width="3.2" fill="none"/><path d="M${x + 19} ${y + 34}h8" stroke="${C.forest}" stroke-width="3.2" stroke-linecap="round"/>`,
};

/// A phone showing Evenda: 'find' (search results) or 'now' (urgent request
/// with offers). Width w; height 2w. Content mirrors real screens, simplified.
export function phone({ x, y, w = 200, screen = 'find', frame = C.ink }) {
  const k = w / 200, id = `ph${++uid}`;
  const card = (cy, g, title, meta, price, cta) => `
    <rect x="14" y="${cy}" width="164" height="58" rx="10" fill="#FFFFFF" stroke="${C.sand}" stroke-width="1.5"/>
    <rect x="22" y="${cy + 8}" width="42" height="42" rx="8" fill="${C.sand}"/>${glyph[g](20, cy + 6)}
    ${t(72, cy + 23, title, 12.5, C.ink, 700)}
    ${t(72, cy + 43, `<tspan fill="${C.forest}" font-weight="700" style="font-variation-settings:'wght' 700">${price}</tspan> · ${meta}`, 10.5, '#4A4F4B', 500)}
    ${cta ? `<rect x="136" y="${cy + 31}" width="36" height="19" rx="9.5" fill="${C.forest}"/>${t(154, cy + 44, cta, 9.5, C.cream, 700, undefined, 'middle')}` : ''}`;
  const screens = {
    find: `${t(14, 52, 'Find stock', 21, C.ink, 560, 'EvFra, Fraunces, serif')}
      <rect x="14" y="64" width="164" height="30" rx="15" fill="#FFFFFF" stroke="${C.sand}" stroke-width="1.5"/>
      ${t(28, 83, 'Chairs · Sat 14 Nov', 11.5, '#4A4F4B', 500)}
      ${card(106, 'chair', 'Chiavari chairs', '3 km', 'K15', 'Book')}
      ${card(172, 'tent', 'Marquee 10×20', '6 km', 'K900', 'Book')}
      ${card(238, 'light', 'Fairy lights', '5 km', 'K25', 'Book')}
      ${t(14, 322, 'Free on your dates, near you', 10.5, C.bronze, 700)}`,
    now: `<path d="M24 34l-6 11h6l-3 9 9-12h-6l3-8z" fill="${C.bronze}"/>${t(36, 52, 'Evenda Now', 21, C.ink, 560, 'EvFra, Fraunces, serif')}
      <rect x="14" y="64" width="164" height="46" rx="10" fill="${C.forest}"/>
      ${t(24, 84, 'Need 80 chairs · Sat', 12.5, C.cream, 700)}${t(24, 100, 'Sent to 9 nearby suppliers', 10.5, C.bronzeLight, 500)}
      ${t(14, 132, '3 offers', 12, C.ink, 700)}
      ${card(142, 'chair', '80 chairs free', '4 km', 'K12', 'Pick')}
      ${card(208, 'chair', '80 chairs free', '7 km', 'K11', 'Pick')}
      ${card(274, 'chair', '60 chairs free', '2 km', 'K13', 'Pick')}`,
  };
  return `<g transform="translate(${x} ${y}) scale(${k})">
    <rect x="0" y="0" width="200" height="400" rx="30" fill="${frame}"/>
    <clipPath id="${id}"><rect x="8" y="8" width="184" height="384" rx="23"/></clipPath>
    <g clip-path="url(#${id})">
      <rect x="8" y="8" width="184" height="384" fill="${C.cream}"/>
      <g transform="translate(4 10)">${screens[screen]}</g>
      <rect x="8" y="350" width="184" height="42" fill="#FFFFFF"/><path d="M8 350h184" stroke="${C.sand}" stroke-width="1.5"/>
      ${[40, 70, 100, 130, 160].map((cx, i) => `<circle cx="${cx}" cy="370" r="${i === 1 ? 7 : 5}" fill="${i === 1 ? C.forest : C.sand}"/>`).join('')}
    </g>
    <rect x="80" y="15" width="40" height="7" rx="3.5" fill="${frame}"/>
  </g>`;
}

// Print layouts in shirt units (600 units ≈ 56 cm chest width for an adult M: ~1 unit = 0.93 mm).
export const shirts = [
  {
    key: 'app-cream',
    name: 'App tee',
    color: C.cream,
    note: 'Says what Evenda is at a glance: the app on a phone, the problem it solves, and a code to get it.',
    front: mark({ x: 368, y: 150, size: 66 }),
    back: `${t(300, 150, 'Short on chairs?', 34, C.forest, 560, 'EvFra, Fraunces, serif', 'middle')}
      ${t(300, 188, 'Find them on Evenda.', 34, C.bronze, 560, 'EvFra, Fraunces, serif', 'middle')}
      ${phone({ x: 168, y: 214, w: 150, screen: 'find' })}
      ${qr({ x: 340, y: 380, size: 92 })}
      ${t(386, 366, 'Get the app', 15, C.ink, 700, undefined, 'middle')}
      ${t(386, 492, 'Android · Google Play', 11, '#4A4F4B', 500, undefined, 'middle')}`,
    spec: 'Front: mark 6 cm, left chest. Back: headline 26 cm wide; phone 14 cm wide; QR 8.5 cm square. Print DTF or DTG (fine detail, 6 colours).',
  },
  {
    key: 'now-forest',
    name: 'Evenda Now tee',
    color: C.forest,
    note: 'The phone is the front: an urgent request for chairs and the offers coming in. The back says how to get it.',
    front: `${phone({ x: 205, y: 120, w: 190, screen: 'now', frame: C.cream })}
      ${t(300, 530, 'Short on stock? Ask nearby suppliers.', 17, C.cream, 600, undefined, 'middle')}`,
    back: `${lockup({ x: 300 - lockupWidth(56) / 2, y: 150, size: 56, ink: C.cream, low: C.bronzeLight })}
      ${t(300, 262, 'FIND STOCK · QUOTE · BOOK', 16, C.bronzeLight, 600, undefined, 'middle')}
      ${qr({ x: 250, y: 300, size: 100, bg: C.cream })}
      ${t(300, 432, 'Scan to get the app', 15, C.cream, 600, undefined, 'middle')}`,
    spec: 'Front: phone 18 cm wide, line 27 cm. Back: lockup 22 cm, QR 9.5 cm square on a cream panel (scanners need dark on light). Print DTF or DTG.',
  },
  {
    key: 'team-cream',
    name: 'Team tee',
    color: C.cream,
    note: 'Cream tee. Small mark on the left chest; full lockup and line across the back.',
    front: mark({ x: 368, y: 150, size: 66 }),
    back: `${lockup({ x: 300 - lockupWidth(60) / 2, y: 175, size: 60 })}
      ${tag('Event vendors in Zambia,', 300, 290, 24, C.ink, 500)}${tag('working together.', 300, 322, 24, C.ink, 500)}`,
    spec: 'Front: mark 6 cm wide, left chest. Back: lockup 25 cm wide, 12 cm below the collar. Inks: forest and bronze (2 colours).',
  },
  {
    key: 'forest',
    name: 'Forest tee',
    color: C.forest,
    note: 'Forest tee for events and launches. Large mark on the front; wordmark on the back.',
    front: mark({ top: C.cream, low: C.bronzeLight, x: 210, y: 180, size: 180 }),
    back: `${tag('evenda', 300, 250, 96, C.cream, 680)}
      ${tag('FIND STOCK · QUOTE · BOOK', 300, 305, 19, C.bronzeLight, 600, 'EvFig, Figtree, sans-serif', 'middle', 3.5)}`,
    spec: 'Front: mark 17 cm wide, centred, 9 cm below the collar. Back: wordmark 26 cm wide. Inks: cream and light bronze (2 colours).',
  },
  {
    key: 'vendor-sand',
    name: 'Vendor tee',
    color: C.sand,
    note: 'Sand tee for vendors to wear at events: who they are on Evenda.',
    front: `${lockup({ x: 300 - lockupWidth(54) / 2, y: 180, size: 54 })}`,
    back: `${mark({ x: 255, y: 140, size: 90 })}
      ${tag('Book my stock', 300, 300, 46, C.forest, 560, 'EvFra, Fraunces, serif')}
      ${tag('on Evenda', 300, 352, 46, C.bronze, 560, 'EvFra, Fraunces, serif')}`,
    spec: 'Front: lockup 18 cm wide, centred. Back: mark 8 cm, line 30 cm wide. Inks: forest and bronze (2 colours).',
  },
];

// --- Build -------------------------------------------------------------------
if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  const work = process.argv[2] ?? '.';
  const root = new URL('../../docs/brand/', import.meta.url).pathname;
  for (const d of ['logo', 'shirts']) mkdirSync(root + d, { recursive: true });
  mkdirSync(work, { recursive: true });

  // Vector logo files (shapes only, no fonts: safe for any printer or app).
  const m = (o) => plainSvg(540, 540, mark({ ...o, size: 540 }));
  writeFileSync(root + 'logo/evenda-mark.svg', m({}));
  writeFileSync(root + 'logo/evenda-mark-on-dark.svg', m({ top: C.cream, low: C.bronzeLight }));
  writeFileSync(root + 'logo/evenda-mark-one-colour-forest.svg', m({ top: C.forest, low: C.forest }));
  writeFileSync(root + 'logo/evenda-mark-one-colour-white.svg', m({ top: '#FFFFFF', low: '#FFFFFF' }));
  writeFileSync(root + 'logo/evenda-mark-one-colour-black.svg', m({ top: '#000000', low: '#000000' }));

  // Raster pages: [file, width, height, html]
  const renders = [];
  const add = (file, w, h, inner, bg) => {
    const name = file.replace(/[/.]/g, '_');
    writeFileSync(`${work}/${name}.html`, page(svg(w, h, inner, bg)));
    renders.push([file, w, h, `${work}/${name}.html`]);
  };
  add('docs/brand/logo/evenda-mark-2048.png', 2048, 2048, mark({ x: 0, y: 0, size: 2048 }));
  const lw = Math.ceil(lockupWidth(400)) + 20;
  add('docs/brand/logo/evenda-lockup-forest.png', lw, 420, lockup({ x: 10, y: 10, size: 400 }));
  add('docs/brand/logo/evenda-lockup-cream.png', lw, 420, lockup({ x: 10, y: 10, size: 400, ink: C.cream, low: C.bronzeLight }));

  // Play feature graphic: cream ground, mark, Fraunces line.
  add('docs/play/assets/feature-graphic-1024x500.png', 1024, 500,
    `${mark({ x: 110, y: 130, size: 240 })}
     ${tag('evenda', 420, 238, 92, C.forest, 680, 'EvFig, Figtree, sans-serif', 'start')}
     ${tag('Event vendors in Zambia,', 424, 310, 38, C.ink, 520, 'EvFra, Fraunces, serif', 'start')}
     ${tag('working together.', 424, 356, 38, C.bronze, 520, 'EvFra, Fraunces, serif', 'start')}`, C.cream);

  for (const s of shirts) {
    for (const view of ['front', 'back']) {
      add(`docs/brand/shirts/evenda-${s.key}-${view}.png`, 1200, 1280,
        `<g transform="scale(2)">${shirt({ color: s.color, view, print: s[view], seam: s.color === C.forest ? 'rgba(0,0,0,.28)' : 'rgba(0,0,0,.10)' })}</g>`);
    }
  }
  writeFileSync(`${work}/renders.json`, JSON.stringify(renders));
  console.log(`${renders.length} renders listed in ${work}/renders.json`);
}

// Generates the Evenda app icon sources (SVG + HTML for rasterising with headless Chrome).
// Usage: node tool/icon/evenda_icon.mjs <out-dir>, then screenshot each <name>.html at 1024x1024
// with --default-background-color=00000000 and copy the PNGs into assets/icon/.
import { writeFileSync } from 'node:fs';
// Evenda icon, final. 1024 canvas = Android adaptive 108dp; safe zone circle r=313.
export const K = { forest: '#1B3B22', bronze: '#A9773F', cream: '#FBF8F1' };
const R = 270, ri = 134, bar = 62, slot = 62, xs = -44;
const y1 = bar / 2, y2 = y1 + slot;
export function mark({ top = K.forest, low = K.bronze } = {}) {
  return `<defs>
    <mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><g transform="translate(512 512)">
      <rect x="-512" y="-512" width="1024" height="1024" fill="#fff"/>
      <path d="M ${-ri} ${-y1} A ${ri} ${ri} 0 0 1 ${ri} ${-y1} Z" fill="#000"/>
      <rect x="${xs}" y="${y1}" width="600" height="${slot}" rx="${slot / 2}" fill="#000"/></g></mask>
    <clipPath id="t"><rect x="0" y="0" width="1024" height="${512 + y2}"/></clipPath>
    <clipPath id="b"><rect x="0" y="${512 + y2}" width="1024" height="1024"/></clipPath></defs>
  <g mask="url(#m)"><circle cx="512" cy="512" r="${R}" fill="${top}" clip-path="url(#t)"/><circle cx="512" cy="512" r="${R}" fill="${low}" clip-path="url(#b)"/></g>`;
}
export const svg = (inner, bg, size = 1024) => `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024">${bg ? `<rect width="1024" height="1024" fill="${bg}"/>` : ''}${inner}</svg>`;
const page = (body) => `<html><head><meta charset="utf-8"></head><body style="margin:0;background:transparent">${body}</body></html>`;
const files = {
  master: svg(mark(), K.cream),
  // Adaptive layers: the launcher shows the middle 72/108 and masks it; 0.8 keeps the disc
  // at ~63% of what is visible and well inside the 66dp safe zone.
  foreground: svg(`<g transform="translate(512 512) scale(0.8) translate(-512 -512)">${mark()}</g>`),
  monochrome: svg(`<g transform="translate(512 512) scale(0.8) translate(-512 -512)">${mark({ top: '#fff', low: '#fff' })}</g>`),
  background: svg('', K.cream),
};
// Write only when run directly (tool/brand imports mark() from here).
if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) for (const [k, v] of Object.entries(files)) { writeFileSync(`${process.argv[2] ?? "."}/${k}.svg`, v); writeFileSync(`${process.argv[2] ?? "."}/${k}.html`, page(v)); }

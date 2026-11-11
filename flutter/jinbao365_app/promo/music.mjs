// Synthesizes the two original music beds for the promo videos. No samples, no third-party audio.
//   node promo/music.mjs <out-dir>
import { mkdirSync, writeFileSync } from 'node:fs';

const RATE = 44100;
const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);

function track(seconds) {
  const n = Math.ceil(seconds * RATE);
  return { left: new Float32Array(n), right: new Float32Array(n), n };
}

/** Adds one decaying note built from sine partials. */
function note(t, { at, midi, gain, length, partials, pan = 0, attack = 0.004 }) {
  const start = Math.floor(at * RATE), count = Math.floor(length * RATE), f = hz(midi);
  const l = Math.cos((pan + 1) * Math.PI / 4), r = Math.sin((pan + 1) * Math.PI / 4);
  for (let i = 0; i < count && start + i < t.n; i++) {
    const time = i / RATE;
    let v = 0;
    for (const [ratio, amp, decay] of partials) v += amp * Math.sin(2 * Math.PI * f * ratio * time) * Math.exp(-decay * time);
    v *= gain * Math.min(1, time / attack) * Math.min(1, (count - i) / (0.02 * RATE));
    t.left[start + i] += v * l;
    t.right[start + i] += v * r;
  }
}

function noise(t, { at, gain, length }) {
  const start = Math.floor(at * RATE), count = Math.floor(length * RATE);
  let seed = start + 1, last = 0;
  for (let i = 0; i < count && start + i < t.n; i++) {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    const white = seed / 2 ** 31 - 1, high = white - last;
    last = white;
    const v = high * gain * Math.exp(-40 * i / RATE);
    t.left[start + i] += v;
    t.right[start + i] += v;
  }
}

/** A quiet stereo echo, then normalisation and fades. */
function finish(t, { echo = 0.3, delay = 0.33, fadeIn = 0.4, fadeOut = 2.5, peak = 0.8 }) {
  const d = Math.floor(delay * RATE);
  for (let i = d; i < t.n; i++) {
    t.left[i] += t.right[i - d] * echo;
    t.right[i] += t.left[i - d] * echo;
  }
  let max = 0;
  for (let i = 0; i < t.n; i++) max = Math.max(max, Math.abs(t.left[i]), Math.abs(t.right[i]));
  const data = Buffer.alloc(44 + t.n * 4);
  data.write('RIFF', 0); data.writeUInt32LE(36 + t.n * 4, 4); data.write('WAVEfmt ', 8);
  data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20); data.writeUInt16LE(2, 22);
  data.writeUInt32LE(RATE, 24); data.writeUInt32LE(RATE * 4, 28); data.writeUInt16LE(4, 32); data.writeUInt16LE(16, 34);
  data.write('data', 36); data.writeUInt32LE(t.n * 4, 40);
  for (let i = 0; i < t.n; i++) {
    const time = i / RATE, left = (t.n - i) / RATE;
    const fade = Math.min(1, time / fadeIn) * Math.min(1, left / fadeOut) * peak / max;
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, t.left[i] * fade)) * 32767), 44 + i * 4);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, t.right[i] * fade)) * 32767), 46 + i * 4);
  }
  return data;
}

const bell = [[1, 1, 3.2], [2, 0.42, 5], [3.01, 0.2, 7], [4.2, 0.1, 10]];
const pad = [[1, 1, 0.5], [2, 0.25, 0.8], [0.5, 0.5, 0.4]];
const pluck = [[1, 1, 7], [2, 0.5, 9], [3, 0.3, 12], [4, 0.16, 15], [5, 0.08, 18]];
const sub = [[1, 1, 2.2], [2, 0.2, 4]];

/** Video A: a warm music-box lullaby, C - G - Am - F at 88 bpm. */
function lullaby(seconds) {
  const t = track(seconds), beat = 60 / 88, bar = beat * 4;
  const chords = [[48, 60, 64, 67, 72], [43, 59, 62, 67, 74], [45, 60, 64, 69, 72], [41, 60, 65, 69, 72]];
  const order = [1, 3, 2, 3, 1, 4, 2, 3];
  const melody = [[76, 0], [79, 2], [76, 3], [74, 0], [79, 2.5], [72, 0], [76, 2], [72, 3.5], [69, 0], [72, 2], [77, 3]];
  for (let b = 0; b * bar < seconds; b++) {
    const chord = chords[b % 4], at = b * bar;
    note(t, { at, midi: chord[0], gain: 0.5, length: bar, partials: sub });
    for (const midi of chord.slice(1, 4)) note(t, { at, midi, gain: 0.07, length: bar * 1.05, partials: pad, attack: 0.5 });
    if (b === 0) continue; // The first bar is only the pad: a breath before the hook lands.
    for (let i = 0; i < 8; i++) {
      note(t, { at: at + i * beat / 2, midi: chord[order[i]], gain: i % 2 ? 0.2 : 0.3, length: 1.6, partials: bell, pan: i % 2 ? 0.35 : -0.35 });
    }
  }
  // A small tune on top, from the third bar on.
  for (let phrase = 0; (phrase * 4 + 2) * bar < seconds - bar; phrase++) {
    let index = 0;
    for (const [midi, offset] of melody) {
      const b = phrase * 4 + 2 + [0, 0, 0, 1, 1, 2, 2, 2, 3, 3, 3][index++];
      note(t, { at: b * bar + offset * beat, midi: midi + 12, gain: 0.22, length: 2.2, partials: bell, pan: 0.1 });
    }
  }
  return finish(t, { echo: 0.28, delay: beat * 0.75 });
}

/** Video B: a steady, lighter pulse, Am - F - C - G at 100 bpm. */
function pulse(seconds) {
  const t = track(seconds), beat = 60 / 100, bar = beat * 4;
  const chords = [[45, 57, 60, 64, 69], [41, 57, 60, 65, 69], [48, 55, 60, 64, 67], [43, 55, 59, 62, 67]];
  const order = [1, 3, 2, 4, 1, 3, 2, 3, 1, 4, 2, 3, 1, 3, 2, 4];
  for (let b = 0; b * bar < seconds; b++) {
    const chord = chords[b % 4], at = b * bar;
    for (const midi of chord.slice(1, 4)) note(t, { at, midi, gain: 0.06, length: bar * 1.05, partials: pad, attack: 0.4 });
    note(t, { at, midi: chord[0], gain: 0.55, length: beat * 2, partials: sub });
    note(t, { at: at + beat * 2.5, midi: chord[0], gain: 0.4, length: beat * 1.5, partials: sub });
    if (b < 1) continue;
    for (let i = 0; i < 16; i++) {
      if (b < 2 && i % 2) continue;
      note(t, { at: at + i * beat / 4, midi: chord[order[i]] + 12, gain: i % 4 === 0 ? 0.26 : 0.15, length: 0.5, partials: pluck, pan: Math.sin(i * 1.3) * 0.5 });
    }
    if (b >= 2) for (let i = 0; i < 4; i++) noise(t, { at: at + (i + 0.5) * beat, gain: 0.05, length: 0.08 });
  }
  return finish(t, { echo: 0.22, delay: beat * 0.75, fadeOut: 3 });
}

const out = process.argv[2] ?? '.';
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/music_a.wav`, lullaby(32));
writeFileSync(`${out}/music_b.wav`, pulse(31));
console.log('music written');

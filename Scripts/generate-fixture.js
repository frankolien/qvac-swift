#!/usr/bin/env node
'use strict'
// Regenerates Tests/QVACWireTests/Fixtures/fixture.json from the REFERENCE
// encoder (bare-rpc + compact-encoding) — not from the Swift implementation.
//
// That distinction is the whole value of the fixture. A round-trip test against
// our own encoder passes just as happily with the endianness reversed; only
// bytes produced by the library the worker actually speaks can catch that.
//
// Setup:
//   npm install compact-encoding b4a bare-rpc
//   cp node_modules/bare-rpc/lib/{messages,constants,errors}.js .
//   node generate-fixture.js > ../Tests/QVACWireTests/Fixtures/fixture.json

const c = require('compact-encoding')
const b4a = require('b4a')
const m = require('./messages.js')
const { type: t, stream: s } = require('./constants.js')

// bare-rpc writes the header and the payload as two separate stream writes;
// on the wire they are contiguous, so the fixture concatenates them.
const frame = (msg) => {
  const header = c.encode(m.header, msg)
  return msg.data ? b4a.concat([header, msg.data]) : header
}
const hex = (b) => b4a.toString(b, 'hex')
const err = (message, code, errno) => Object.assign(new Error(message), { code, errno })

// Deterministic PRNG: the fixture is committed, so it must not churn between
// runs. A diff in this file should always mean the protocol changed.
let seed = 42
const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296 }
const ri = (n) => Math.floor(rnd() * n)

const vectors = []
const add = (name, msg) => vectors.push({ name, msg })

// Varint width boundaries on every field that carries one. Each value sits one
// byte either side of a width transition (0xfc/0xfd, 0xffff/0x10000, ...).
const BOUNDS = [0, 1, 0xfc, 0xfd, 0xff, 0x100, 0xffff, 0x10000, 0xffffffff, 0x100000000]
for (const v of BOUNDS) {
  add(`bound_id_${v}`, { type: t.REQUEST, id: v, command: 1, stream: 0, data: b4a.from('a') })
  add(`bound_cmd_${v}`, { type: t.REQUEST, id: 1, command: v, stream: 0, data: b4a.from('a') })
}

// Zigzag sweep. Negative errnos are real (libuv uses them), and sign handling
// is the classic place a hand-written varint goes wrong.
for (const e of [0, 1, -1, 2, -2, 127, -128, 52401, -52401, 2147483647]) {
  add(`errno_${e}`, { type: t.STREAM, id: 7, stream: s.ERROR, error: err('e', 'C', e) })
}

// Payload sizes straddling the length-prefix transitions.
for (const n of [0, 1, 0xfc, 0xfd, 0xffff, 0x10000]) {
  add(`payload_${n}`, { type: t.STREAM, id: 8, stream: s.DATA, data: b4a.alloc(n, 0x61) })
}

// Flag combinations, including the composites that prove this is a bitmask.
for (const f of [s.OPEN, s.CLOSE, s.PAUSE, s.RESUME, s.END, s.DESTROY,
                 s.OPEN | s.REQUEST, s.OPEN | s.RESPONSE, s.CLOSE | s.END]) {
  add(`flags_${f}`, { type: t.STREAM, id: 9, stream: f })
}

// Randomised coverage across all three message types.
for (let i = 0; i < 40; i++) {
  const kind = ri(3) + 1
  const id = ri(200000)
  if (kind === t.REQUEST) {
    add(`fuzz_${i}`, { type: t.REQUEST, id, command: ri(100000), stream: 0,
                       data: b4a.from(JSON.stringify({ i, v: 'x'.repeat(ri(300)) })) })
  } else if (kind === t.RESPONSE) {
    add(`fuzz_${i}`, { type: t.RESPONSE, id, stream: 0, error: null,
                       data: b4a.from(JSON.stringify({ ok: true, n: i })) })
  } else {
    add(`fuzz_${i}`, { type: t.STREAM, id, stream: s.DATA,
                       data: b4a.from(JSON.stringify({ tok: `t${i}` }) + '\n') })
  }
}

const frames = vectors.map(({ name, msg }) => ({
  name,
  hex: hex(frame(msg)),
  expect: {
    type: msg.type,
    id: msg.id,
    command: msg.command ?? null,
    stream: msg.stream,
    dataHex: msg.data ? hex(msg.data) : null,
    errno: msg.error ? msg.error.errno : null,
    code: msg.error ? msg.error.code : null,
    message: msg.error ? msg.error.message : null
  }
}))

// Every frame back to back — the input for the reassembly tests, which replay
// it at chunk sizes down to a single byte.
const concatenated = hex(b4a.concat(vectors.map(({ msg }) => frame(msg))))

process.stdout.write(JSON.stringify({ frames, concatenated, frameCount: frames.length }, null, 1))

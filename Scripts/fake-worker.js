#!/usr/bin/env node
'use strict'
// A stand-in Bare worker for integration tests. It speaks REAL bare-rpc — the
// same library the QVAC worker links — and dials IN to the listening client,
// which is the actual transport direction (`node-rpc-client.ts` listens, the
// worker connects). If the Swift side got the direction, the framing, or the
// stream protocol wrong, this process notices, not a mock.
//
// Usage: node fake-worker.js <tcp://host:port | unix-socket-path>

const net = require('net')
const RPC = require('bare-rpc')

const COMMANDS = {
  ECHO: 100, // unary: replies with the request payload
  TOKENS: 101, // response stream: 5 NDJSON records + unterminated trailer
  FAIL: 102, // throws → protocol-level RPC error
  BYE: 103 // replies, then exits cleanly
}

const endpoint = process.argv[2]
if (!endpoint) {
  console.error('usage: fake-worker.js <tcp://host:port | unix-socket-path>')
  process.exit(2)
}

const socket = endpoint.startsWith('tcp://')
  ? (() => {
      const url = new URL(endpoint)
      return net.connect(Number(url.port), url.hostname)
    })()
  : net.connect(endpoint)

socket.on('error', (err) => {
  console.error('fake-worker socket error:', err.message)
  process.exit(1)
})

socket.on('connect', () => {
  new RPC(socket, async (req) => {
    // Duplex: the request arrives with no data — the real payload is the
    // first record on the request stream, one JSON record per DATA frame
    // (exactly how the QVAC server's handleDuplexRequest reads it). Replies
    // are NDJSON. Echo protocol: ack the first record, echo the rest,
    // acknowledge END with a done record.
    if (!req.data) {
      const input = req.createRequestStream()
      const output = req.createResponseStream()
      let first = true
      input.on('data', (chunk) => {
        const record = JSON.parse(chunk.toString())
        if (first) {
          first = false
          output.write(Buffer.from(JSON.stringify({ ready: true, method: record.type ?? null }) + '\n'))
        } else {
          output.write(Buffer.from(JSON.stringify({ echo: record }) + '\n'))
        }
      })
      input.on('end', () => {
        output.write(Buffer.from(JSON.stringify({ done: true })))
        output.end()
      })
      input.on('error', () => output.destroy())
      return
    }

    switch (req.command) {
      case COMMANDS.ECHO:
        req.reply(req.data)
        break

      case COMMANDS.TOKENS: {
        const stream = req.createResponseStream()
        for (let i = 0; i < 5; i++) {
          stream.write(Buffer.from(JSON.stringify({ tok: `t${i}` }) + '\n'))
        }
        // A trailing record with no newline — the shape the QVAC Python
        // client documents; a consumer without flush() loses it.
        stream.write(Buffer.from(JSON.stringify({ done: true })))
        stream.end()
        break
      }

      case COMMANDS.FAIL: {
        const err = new Error('deliberate failure')
        err.code = 'EDELIBERATE'
        err.errno = -42
        throw err
      }

      case COMMANDS.BYE:
        req.reply(Buffer.from('bye'))
        setTimeout(() => {
          socket.end()
          process.exit(0)
        }, 10)
        break

      default: {
        const err = new Error(`unknown command ${req.command}`)
        err.code = 'EUNKNOWN'
        err.errno = -1
        throw err
      }
    }
  })
})

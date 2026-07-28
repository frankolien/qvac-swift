# QVACClient — Design

A native Swift client for the [QVAC SDK](https://github.com/tetherto/qvac):
LLM inference, speech, RAG, translation, diffusion and more, running entirely
on-device, callable from Swift with `async`/`await` and `AsyncSequence` — no
JavaScript at the call site.

This document records the architecture, the verified wire protocol, and the
findings from reading the SDK source that shape the design. The wire layer
(`QVACWire`), the session layer (`QVACSession`), and the desktop socket
transport are implemented and tested — including live against a real
`bare-rpc` peer. The iOS worklet transport and the generated API surface are
designed here and not yet built.

## What this is — and is not

QVAC's inference happens in a separate **Bare worker** (a process on desktop, an
embedded worklet on mobile). The SDK's JS client is an RPC consumer talking to
that worker; any language that speaks the RPC protocol can be a client, which
`sdk-python` already demonstrates.

`QVACClient` is therefore **a client, not a runtime**. The Bare worker keeps
every meaningful responsibility: spawning, model management, addon
orchestration, inference. The Swift side implements only the consumer half of
the RPC protocol plus a typed API surface over it. It does not modify the
worker, the RPC server, or the addon layer, and it does not reimplement
inference, model download, or P2P logic.

## Three findings that shape the architecture

These come from reading the SDK source (`tetherto/qvac`, HEAD 2026-07-27), and
each one corrects an assumption a naive port would make.

**1. The transport direction is inverted.** In
`packages/sdk/client/rpc/node-rpc-client.ts` the client calls `createServer()`
and `listen(socketPath)` *before* spawning the worker, passing the path in via
the worker's argument. The worker dials in. The Swift transport is a listener
with an accept loop, not a `connect()` call. Additionally,
`server/rpc/create-server.ts` accepts a `tcp://host:port` endpoint as well as a
filesystem socket path — `sdk-python` uses loopback TCP on every OS to avoid
platform-specific server APIs.

**2. iOS cannot spawn subprocesses**, so the socket transport cannot cover it.
The Expo client instead starts a `Worklet` and uses `worklet.IPC` — an
in-memory duplex — as the transport. `holepunchto/bare-kit-swift` exposes this
natively: `Worklet` with `start`/`suspend`/`resume`/`terminate`, and `IPC`,
which is already an `AsyncSequence` of `Data`. The React Native layer is only a
wrapper over that native framework, so the Swift client embeds Bare directly.
Net result: **two thin transports behind one protocol**, not one transport with
a platform caveat.

**3. Code generation should read `contract/`, not TypeScript.**
`packages/sdk/contract/` is a language-neutral wire contract — `schema.json`
(JSON Schema 2020-12) plus `manifest.json` — and its README states generated
clients are built from those artifacts. `sdk-python`'s `scripts/generate.py`
does exactly that. Against the current manifest the surface is **37 methods
across three call shapes** (`request-reply`, `server-stream`, `duplex`); the
nine RAG operations are a single `rag` method discriminated by an `operation`
field.

## The wire protocol, verified

Established by reading `bare-rpc` and `compact-encoding` source, then confirmed
byte-for-byte against 85 vectors generated from the reference JS encoder (see
`README.md` for the fixture methodology).

**Framing.** A `uint32` little-endian body length, then the body. The prefix
counts the body only. `bare-rpc`'s `_onmessage` receives the frame *with* its
prefix and re-reads the `uint32` before parsing; `QVACWire` keeps that
convention so offsets compare directly against the reference when debugging.

**Integers** are Bitcoin-style CompactSize varints, little-endian: one byte up
to `0xfc`; `0xfd` + `uint16` LE; `0xfe` + `uint32` LE; `0xff` + `uint64` LE.
**Signed integers are zigzagged** over that (errno 52401 → 104802; −3 → 5;
negative errnos are real — libuv uses them). **Booleans** are a single raw
byte. **Strings** are a varint *byte* count then UTF-8 bytes.

**Messages** are `REQUEST = 1`, `RESPONSE = 2`, `STREAM = 3`:

- REQUEST: varint type, id, command, stream flags; payload only when flags == 0.
  A REQUEST with `id == 0` is a fire-and-forget event, not a request awaiting a
  reply.
- RESPONSE: varint type, id; bool error flag; varint stream flags; then an
  error struct, or a payload when flags == 0.
- STREAM: varint type, id, stream flags; then an error struct if `ERROR` is
  set, a payload if `DATA` is set, or nothing.
- Error struct: UTF-8 message, UTF-8 code, zigzag errno.

**Stream flags are a bitmask**, not an enum — `OPEN|REQUEST` (0x101) is one
legitimate value: `OPEN 0x1`, `CLOSE 0x2`, `PAUSE 0x4`, `RESUME 0x8`,
`DATA 0x10`, `END 0x20`, `DESTROY 0x40`, `ERROR 0x80`, `REQUEST 0x100`,
`RESPONSE 0x200`.

**Payloads are JSON; streamed payloads are NDJSON inside the frames** — one
frame may carry several records and one record may span frames. Two independent
framing layers, which is why `NDJSONSplitter` exists, and why its `flush()` is
mandatory (the Python client emits a trailing unterminated record).

**Application errors arrive in band** as `{"type":"error", ...}` JSON on the
success path, distinct from protocol-level RPC errors. Both paths must be
handled. `contract/error-codes.json` carries 95 server codes, 38 client codes,
and 3 registry codes.

**Handshake.** Command `1` carries `{"type":"__init_config", config,
runtimeContext}`; the reply is `{success, error?}`, and config is immutable
worker-side afterwards. Command `1` also carries `{"type":"__shutdown__"}` for
pre-terminate cleanup — required on iOS, where terminating the worklet without
it triggers a documented V8 GlobalHandle assertion (SIGTRAP) when addon state
outlives the isolate.

## Layered architecture

```
┌──────────────────────────────────────────────┐
│  QVACClient — generated typed API surface    │  swift run qvac-codegen
├──────────────────────────────────────────────┤
│  RPCSession (actor) — multiplexing,          │
│  cancellation source, PAUSE/RESUME           │
│  backpressure, NDJSON record streams         │
├──────────────────────────────────────────────┤
│  Transport protocol (~3 requirements)        │
│  ├─ SocketTransport   macOS: listen + spawn  │
│  └─ WorkletTransport  iOS: BareKit worklet   │
├──────────────────────────────────────────────┤
│  QVACWire — frame codec, varints,            │  ← implemented, verified
│  FrameDecoder reassembly, NDJSONSplitter     │
└──────────────────────────────────────────────┘
```

**Session layer.** A single `actor RPCSession` owns all mutable state: the
pending-reply table (`[UInt64: CheckedContinuation]`), open streams, the ID
counter, and the decoder. Actor isolation provides the multiplexing invariants;
one detached read task drives the decode loop and hands messages to the actor.

Two things go in on day one because they are painful to retrofit:

- *A cancellation source.* The JS client documents that when the channel dies,
  `bare-rpc` does not iterate its outstanding requests, so pending replies hang
  forever on a dead socket; its fix is a "worker life signal" raced against
  every pending operation. The Swift equivalent is one cancellation source held
  by the session, registered by every continuation, so transport death fails
  everything at once with a typed error.
- *Backpressure.* Track consumer demand; emit `PAUSE` at a high-water mark and
  `RESUME` at a low-water mark, with hysteresis so a fast token stream doesn't
  thrash one control frame per token. `AsyncStream`'s buffering policy is not
  backpressure — it drops silently.

Cancellation maps cleanly onto structured concurrency:
`AsyncStream.onTermination` fires the `cancel` RPC and sends `DESTROY`.

**Transports.** Roughly 150 lines each behind a minimal protocol
(`send(Data)`, an inbound `AsyncStream<Data>`, `close()`). Keeping that seam
narrow is what lets everything above it be tested with a `MockTransport`, with
no Bare binary present.

**Generator.** Swift-hosted (`swift run qvac-codegen`) with a `--check` mode
mirroring the SDK's `contract:check`. Off-the-shelf options were evaluated and
rejected: `quicktype` is weak on discriminated unions, ignores
`x-enum-varnames`, and its output churns between versions, breaking the
"regeneration produces no diff" requirement; `swift-openapi-generator` needs an
OpenAPI document, and the shim from raw JSON Schema is lossy.

Emission is a graph problem: build nodes from the schema `$defs` plus every
titled nested schema, topologically sort by `$ref` edges, detect cycles and
break them with `indirect enum` or a boxed class (Swift structs cannot be
recursive by value). Resolve name collisions by qualifying with the parent
path — never a counter, which is order-sensitive and breaks deterministic
regeneration. Emit with sorted iteration everywhere. Discriminated unions
become an `enum` with an associated value per arm and an `init(from:)` that
peeks the discriminator; undiscriminated ones (e.g. `finetune`'s shapes,
distinguished by field presence) attempt most-specific-first with a failure
diagnostic that names every arm tried.

**Progress promotion.** Four methods (`loadModel`, `downloadAsset`, `rag`,
`finetune`) switch from unary reply to a stream when `withProgress` is set
(`rag`/`finetune` additionally gate on `operation`), with progress events and
the final result distinguished only by each payload's `type` field. The
manifest expresses the condition as a JavaScript string, which a non-JS
generator cannot evaluate — so the four predicates are hand-written and
asserted against the manifest string in a test. (A structural encoding of the
condition upstream would simplify every future generated client.) The API
surfaces progress as overloads — `loadModel(...)` and
`loadModel(..., onProgress:)` — not as a union return type.

**Errors.** A generated `QVACError` keyed on code, with
`.unknown(code:message:)` so an SDK that adds a code doesn't break a compiled
client, mirroring `rpc-error.ts`'s reconstruction.

## Platform & CI

Targets macOS 14 / iOS 17. BareKit itself supports lower (macOS 11 / iOS 14),
so raising support later is not blocked. `QVACWire` ships as its own SPM
product with no BareKit dependency, so the protocol suite runs on Linux CI on
every commit; the full matrix adds macOS arm64, an iOS 17 simulator, and a job
asserting generator output is current.

## Open questions

Deliberately unresolved pending upstream input:

1. Which `@qvac/sdk` version should the client pin? (`sdk-python` tracks the
   SDK version it speaks.)
2. Loopback TCP or AF_UNIX on macOS? Python ships TCP everywhere.
3. Is `bare-kit-swift` a blessed dependency, or should BareKit be vendored?
4. Should generated P2P methods (`provide`, `stopProvide`, `suspend`,
   `resume`) ship, or stay gated behind a flag? A contract-driven generator
   emits them either way.
5. Would a PR making `manifest.json`'s `progress.condition` structural (rather
   than a JS string) be accepted?

## Provenance

Every protocol claim traces to source read directly:

| Claim | Source |
|---|---|
| Client listens, worker dials in | `packages/sdk/client/rpc/node-rpc-client.ts` |
| iOS worklet transport, `__shutdown__` SIGTRAP | `packages/sdk/client/rpc/expo-rpc-client.ts` |
| `__init_config` handshake | `packages/sdk/client/init-hooks.ts` |
| Dead-channel hang, life-signal fix | `packages/sdk/client/rpc/rpc-client.ts` |
| Contract is the codegen input | `packages/sdk/contract/README.md` |
| 37 methods, call shapes, progress conditions | `packages/sdk/contract/manifest.json` |
| 136 error codes | `packages/sdk/contract/error-codes.json` |
| `tcp://` endpoint support | `packages/sdk/server/rpc/create-server.ts` |
| Prior-art generated client | `packages/sdk-python/scripts/generate.py` |
| NDJSON framing, TCP rationale, trailing record | `packages/sdk-python/src/.../bare_rpc_transport.py` |
| Frame layout, flags, message shapes | `bare-rpc` — `index.js`, `lib/messages.js`, `lib/constants.js` |
| Varint format | `compact-encoding/index.js` |
| Swift worklet API | `bare-kit-swift/Sources/BareKit/{IPC,Worklet}.swift` |

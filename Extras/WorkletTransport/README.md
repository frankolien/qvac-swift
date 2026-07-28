# WorkletTransport (iOS / embedded Bare)

The mobile half of the transport story: iOS cannot spawn subprocesses, so the
worker runs as an embedded Bare **worklet** and the transport is BareKit's
in-memory IPC duplex. `WorkletTransport.swift` adapts it to this package's
3-requirement `Transport` seam — everything above (session, typed client) is
identical to desktop.

## Why a copy-in file and not a package target

`holepunchto/bare-kit-swift` is an SPM package, but its `BareKitBridge`
target declares `.linkedFramework("BareKit")` **without vendoring a binary**
— the `BareKit.framework`/xcframework must be provided by the embedding app
(it ships via the `bare-kit` npm package or CocoaPods). Declaring
`bare-kit-swift` as a dependency here would therefore break `swift build`
and CI for every consumer that hasn't embedded the framework — including
pure-desktop users who never touch iOS.

This is also an open scoping question upstream (blessed dependency vs
vendored framework); a copy-in keeps that decision unmade without blocking
anyone. When it's settled, this file becomes a real target behind the same
seam, unchanged.

## Use

1. Embed BareKit in the app (npm `bare-kit`, or CocoaPods) and add
   `bare-kit-swift` as a package dependency of the *app*.
2. Bundle the QVAC worker for Bare and start a worklet with it:

   ```swift
   import BareKit

   let worklet = Worklet()
   try worklet.start("/worker.bundle", ofType: "bundle", in: .main)
   ```

3. Drop `WorkletTransport.swift` into the app target, then:

   ```swift
   import QVACClient
   import QVACSession

   let client = QVACClient(transport: WorkletTransport(worklet: worklet))
   try await client.initialize()
   let reply = try await client.heartbeat(HeartbeatRequest())
   ```

4. Always tear down through `await client.shutdown()`. It performs the
   `__shutdown__` roundtrip *before* the transport terminates the worklet —
   skipping that ordering trips a documented V8 GlobalHandle assertion
   (SIGTRAP) when addon state outlives the isolate.

`Worklet.suspend(linger:)`/`resume()` remain available on the worklet you
own, for app lifecycle events; the transport does not manage those.

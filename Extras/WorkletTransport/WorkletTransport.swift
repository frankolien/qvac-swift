// The iOS/mobile transport: an embedded Bare worklet instead of a spawned
// process (iOS cannot spawn subprocesses). Drop this file into an app that
// embeds BareKit — see the README next to it for why this is a copy-in
// rather than a package target.
//
// BareKit's `IPC` is already an `AsyncSequence` of `Data`, so the adaptation
// to `Transport` is nearly free: same frames, same session, same client —
// only the carrier differs from desktop.

import BareKit
import Foundation
import QVACSession

public final class WorkletTransport: Transport, @unchecked Sendable {

    public let inbound: AsyncThrowingStream<Data, Swift.Error>
    private let ipc: IPC
    private let worklet: Worklet
    private let pump: Task<Void, Never>

    /// The worklet must already be `start`ed with the QVAC worker bundle.
    /// The transport takes over the IPC duplex and, on `close()`, terminates
    /// the worklet.
    ///
    /// Teardown ordering matters: use `QVACClient.shutdown()`, which performs
    /// the `__shutdown__` roundtrip *before* the session closes this
    /// transport — terminating a worklet with live addon state trips a
    /// documented V8 GlobalHandle assertion (SIGTRAP).
    public init(worklet: Worklet) {
        self.worklet = worklet
        let ipc = IPC(worklet: worklet)
        self.ipc = ipc

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.inbound = stream
        self.pump = Task {
            do {
                while let chunk = try await ipc.read() {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await ipc.write(data: data)
    }

    public func close() async {
        pump.cancel()
        ipc.close()
        worklet.terminate()
    }
}

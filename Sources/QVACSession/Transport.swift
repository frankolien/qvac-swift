import Foundation

/// The seam between the session layer and the bytes.
///
/// Deliberately minimal — three requirements — so that every concrete carrier
/// (a socket listener on macOS, a BareKit worklet IPC duplex on iOS, a mock in
/// tests) stays ~150 lines, and everything above the seam can be exercised
/// with no Bare binary present.
///
/// Chunking carries no meaning: `inbound` delivers whatever the kernel or the
/// worklet produced — half a frame, forty frames, one byte. Framing is the
/// session's job.
public protocol Transport: Sendable {
    /// Raw inbound bytes. Finishing (with or without an error) means the
    /// carrier is dead: the session tears down and fails every pending
    /// operation, mirroring `bare-rpc`'s channel-closed semantics.
    var inbound: AsyncThrowingStream<Data, Swift.Error> { get }

    /// Writes one buffer to the carrier. The session serialises calls — a
    /// conforming transport never sees interleaved sends.
    func send(_ data: Data) async throws

    /// Tears down the carrier. Must cause `inbound` to finish.
    func close() async
}

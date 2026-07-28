import XCTest
import QVACClient
import QVACSession

/// The whole stack against the REAL `@qvac/sdk` worker — not the reference
/// library, not a fake: the actual bundle Tether ships, under the actual
/// `bare` runtime, spawned by our launcher, spoken to by our session, through
/// the generated surface.
///
/// Opt-in (the SDK install is >1 GB of inference prebuilds): set
/// `QVAC_E2E_DIR` to a directory where `npm install @qvac/sdk` has run.
final class RealWorkerTests: XCTestCase {

    struct SDKInstall {
        let workerPath: String
        let barePath: String
        let homeDirectory: String
    }

    private func requireSDK() throws -> SDKInstall {
        guard let root = ProcessInfo.processInfo.environment["QVAC_E2E_DIR"] else {
            throw XCTSkip("set QVAC_E2E_DIR to a directory containing node_modules/@qvac/sdk")
        }
        let worker = "\(root)/node_modules/@qvac/sdk/dist/server/worker.js"
        let bare = "\(root)/node_modules/bare-runtime/bin/bare"
        for path in [worker, bare] {
            try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "missing \(path)")
        }
        // A scratch HOME_DIR keeps worker caches out of the real home.
        let home = "\(root)/qvac-home"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return SDKInstall(workerPath: worker, barePath: bare, homeDirectory: home)
    }

    func testRealWorkerHandshakeStateAndRegistry() async throws {
        let sdk = try requireSDK()

        let session = try await withTimeout(30, label: "spawn + __init_config") {
            try await QVACClient.launchWorker(
                runtime: sdk.barePath,
                workerPath: sdk.workerPath,
                homeDirectory: sdk.homeDirectory)
        }

        do {
            // `state` — request-reply through the generated surface, decoded
            // into generated types, against the real registry implementation.
            let state = try await withTimeout(15, label: "state") {
                try await session.client.state(StateRequest())
            }
            print("REAL WORKER state: \(state)")

            // The model registry — a heavier real code path (registry load).
            let registry = try await withTimeout(60, label: "modelRegistryList") {
                try await session.client.modelRegistryList(ModelRegistryListRequest())
            }
            print("REAL WORKER registry entries: \(String(describing: registry).prefix(400))")
        } catch {
            let worker = session.worker
            XCTFail("""
                real-worker call failed: \(error)
                worker stderr tail:
                \(worker.stderrTail)
                """)
        }

        await session.shutdown()
        // The real worker unwinds addons before exiting on SIGTERM — allow a
        // realistic grace period (the supervisor escalates to SIGKILL at 10s).
        let deadline = Date().addingTimeInterval(20)
        while session.worker.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertFalse(session.worker.isRunning, "worker should exit after shutdown + SIGTERM (or SIGKILL backstop)")
    }
}

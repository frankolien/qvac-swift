// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QVACClient",
    // Matches the grant's target matrix. BareKit itself goes lower (macOS 11 /
    // iOS 14), so raising these later is not blocked by the dependency.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The wire layer ships as its own product: it has no dependency on
        // BareKit, no dependency on a Bare binary, and therefore builds and
        // tests on Linux CI. Keeping it separable is what makes the protocol
        // suite cheap to run on every commit.
        .library(name: "QVACWire", targets: ["QVACWire"]),
        // The session layer: multiplexing, flow control, and lifetime
        // management over any byte transport. Also Bare-free and Linux-testable
        // through a mock transport.
        .library(name: "QVACSession", targets: ["QVACSession"])
    ],
    targets: [
        .target(name: "QVACWire"),
        .target(name: "QVACSession", dependencies: ["QVACWire"]),
        .testTarget(
            name: "QVACWireTests",
            dependencies: ["QVACWire"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "QVACSessionTests",
            dependencies: ["QVACSession"]
        ),
        // End-to-end against a REAL bare-rpc peer: a Node fake worker dials
        // into the Swift listener and the whole stack — sockets, framing,
        // session, NDJSON — is exercised with reference bytes. Skips itself
        // when node or Scripts/node_modules is unavailable.
        .testTarget(
            name: "QVACIntegrationTests",
            dependencies: ["QVACSession"]
        )
    ]
)

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
        .library(name: "QVACWire", targets: ["QVACWire"])
    ],
    targets: [
        .target(name: "QVACWire"),
        .testTarget(
            name: "QVACWireTests",
            dependencies: ["QVACWire"],
            resources: [.process("Fixtures")]
        )
    ]
)

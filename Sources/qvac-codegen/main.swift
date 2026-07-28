import Foundation
import QVACCodegenCore

// swift run qvac-codegen [--check] [--contract <dir>] [--output <dir>]
//
// Regenerates Sources/QVACClient/Generated/ from contract/. With --check,
// writes nothing and exits 1 when the committed output is stale — the CI
// guard mirroring the SDK's own `contract:check`.

var contractPath = "contract"
var outputPath = "Sources/QVACClient/Generated"
var checkOnly = false

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--check":
        checkOnly = true
    case "--contract":
        guard let value = arguments.first else { fatalError("--contract needs a path") }
        contractPath = value
        arguments.removeFirst()
    case "--output":
        guard let value = arguments.first else { fatalError("--output needs a path") }
        outputPath = value
        arguments.removeFirst()
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        exit(2)
    }
}

do {
    let output = try Codegen.generate(contractDirectory: URL(fileURLWithPath: contractPath))
    let outputDirectory = URL(fileURLWithPath: outputPath)

    if checkOnly {
        var stale: [String] = []
        for name in output.files.keys.sorted() {
            let committed = try? String(contentsOf: outputDirectory.appendingPathComponent(name), encoding: .utf8)
            if committed != output.files[name] { stale.append(name) }
        }
        guard stale.isEmpty else {
            print("STALE: \(stale.joined(separator: ", ")) — run `swift run qvac-codegen`")
            exit(1)
        }
        print("generated output is current (\(output.files.count) files)")
    } else {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for name in output.files.keys.sorted() {
            try output.files[name]!.write(
                to: outputDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            print("wrote \(outputPath)/\(name) (\(output.files[name]!.count) chars)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("qvac-codegen: \(error)\n".utf8))
    exit(1)
}

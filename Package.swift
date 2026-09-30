// swift-tools-version: 6.2
import PackageDescription

// DeskMate is built with SwiftPM so the same sources build with Command Line Tools
// or full Xcode. `scripts/build-app.sh` assembles and signs the .app bundle.
let package = Package(
    name: "DeskMate",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DeskMate", targets: ["DeskMate"]),
        .executable(name: "DeskMateMCPFixture", targets: ["DeskMateMCPFixture"]),
    ],
    targets: [
        // Non-UI logic: model session, library, conversations, connections, assistant tools.
        .target(name: "DeskMateCore", dependencies: ["DeskMateShared"], path: "App/Core"),
        // Types safe to share with the widget extension (snapshot, routes). Never document text, prompts or secrets.
        .target(name: "DeskMateShared", path: "Shared"),
        // SwiftUI application.
        .executableTarget(name: "DeskMate", dependencies: ["DeskMateCore", "DeskMateShared"], path: "App/UI"),
        // Controlled synthetic loopback MCP server for demonstrations and tests.
        .executableTarget(name: "DeskMateMCPFixture", path: "Tools/MCPFixture"),
        .testTarget(name: "DeskMateCoreTests", dependencies: ["DeskMateCore", "DeskMateShared"], path: "Tests/DeskMateCoreTests"),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

// DeskMate is built with SwiftPM so the same sources build with Command Line Tools
// or full Xcode. `scripts/build-app.sh` assembles and signs the .app bundle.
let package = Package(
    name: "DeskMate",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DeskMate", targets: ["DeskMate"]),
        .executable(name: "DeskMateWidget", targets: ["DeskMateWidget"]),
        .executable(name: "DeskMateMCPFixture", targets: ["DeskMateMCPFixture"]),
        .executable(name: "DeskMateMCPCheck", targets: ["DeskMateMCPCheck"]),
    ],
    dependencies: [
        // Official MCP Swift SDK, pinned exactly. Streamable HTTP client (and test/fixture server primitives).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // The SDK's Transport protocol is expressed in swift-log types; pinned to the version the SDK resolves to.
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
    ],
    targets: [
        // Non-UI logic: model session, library, conversations, connections, assistant tools.
        .target(
            name: "DeskMateCore",
            dependencies: [
                "DeskMateShared",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "App/Core"
        ),
        // Types safe to share with the widget extension (snapshot, routes). Never document text, prompts or secrets.
        .target(name: "DeskMateShared", path: "Shared"),
        // SwiftUI application.
        .executableTarget(name: "DeskMate", dependencies: ["DeskMateCore", "DeskMateShared"], path: "App/UI"),
        // WidgetKit extension. Reads only the generic snapshot (DeskMateShared); no model, network or conversation code.
        // Built as an extension executable: application-extension-safe APIs only, entered through _NSExtensionMain
        // instead of main. scripts/build-app.sh places it in the app as Contents/PlugIns/DeskMateWidget.appex.
        .executableTarget(
            name: "DeskMateWidget",
            dependencies: ["DeskMateShared"],
            path: "Widget",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        // Synthetic loopback MCP server (library), shared by the fixture executable and the tests.
        .target(
            name: "DeskMateMCPFixtureKit",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tools/MCPFixtureKit"
        ),
        // Controlled synthetic loopback MCP server for demonstrations and tests.
        .executableTarget(
            name: "DeskMateMCPFixture",
            dependencies: ["DeskMateMCPFixtureKit"],
            path: "Tools/MCPFixture"
        ),
        // Headless client check: drives the real connection manager against an endpoint and prints the outcome.
        .executableTarget(
            name: "DeskMateMCPCheck",
            dependencies: ["DeskMateCore", "DeskMateMCPFixtureKit"],
            path: "Tools/MCPCheck"
        ),
        .testTarget(
            name: "DeskMateCoreTests",
            dependencies: ["DeskMateCore", "DeskMateShared", "DeskMateMCPFixtureKit"],
            path: "Tests/DeskMateCoreTests"
        ),
    ]
)

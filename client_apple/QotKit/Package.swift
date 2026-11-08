// swift-tools-version: 6.2
//
// QotKit: the notes store every Apple target shares (app, widgets, intents,
// later the Mac; the Watch hands notes to the phone instead). It wraps qot_core through UniFFI; the framework
// and bindings are built by `mise run build:apple-core` and gitignored.
import PackageDescription

let package = Package(
    name: "QotKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "QotKit", targets: ["QotKit"])
    ],
    targets: [
        .binaryTarget(name: "QotFFI", path: "QotFFI.xcframework"),
        .target(name: "QotKit", dependencies: ["QotFFI"]),
        .testTarget(name: "QotKitTests", dependencies: ["QotKit"]),
    ]
)

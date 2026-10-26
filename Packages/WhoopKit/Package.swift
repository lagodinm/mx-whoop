// swift-tools-version:5.9
import PackageDescription

// WhoopKit is deliberately platform-neutral: no CoreBluetooth, no UIKit.
// Everything here (framing, parsing, analytics, lie-detector model) can be
// unit-tested with `swift test` on any machine with a Swift toolchain.
let package = Package(
    name: "WhoopKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WhoopKit", targets: ["WhoopKit"]),
    ],
    targets: [
        .target(name: "WhoopKit"),
        .testTarget(name: "WhoopKitTests", dependencies: ["WhoopKit"]),
    ]
)

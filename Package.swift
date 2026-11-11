// swift-tools-version:5.10
import PackageDescription

// TDLib comes in as a prebuilt xcframework (TDLibFramework), so builds only
// compile Toss's own sources. Toss talks to TDLib through its JSON interface
// instead of TDLibKit's ~170k lines of generated Swift, which keeps clean
// builds fast.
let package = Package(
    name: "Toss",
    // TDLibFramework 1.8.69 objects are built for macOS 15.
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibFramework", exact: "1.8.69-1f390d90"),
    ],
    targets: [
        .executableTarget(
            name: "Toss",
            dependencies: [
                "TapDetection",
                .product(name: "TDLibFramework", package: "TDLibFramework"),
            ],
            path: "Sources/Toss",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // The Option double-tap state machine, kept apart so it can be unit-tested
        // without TDLib.
        .target(name: "TapDetection", path: "Sources/TapDetection"),
        .testTarget(name: "TapDetectionTests", dependencies: ["TapDetection"], path: "Tests/TapDetectionTests"),
    ]
)

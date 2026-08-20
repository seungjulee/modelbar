// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelBar",
    // String form rather than the `.v26` case so this keeps building on
    // toolchains whose PackageDescription predates the macOS 26 enum case.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ModelBar",
            path: "Sources/ModelBar",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

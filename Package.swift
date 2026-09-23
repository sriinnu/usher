// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Usher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Usher", targets: ["Usher"])
    ],
    targets: [
        .executableTarget(
            name: "Usher",
            path: "Sources/Usher",
            // Swift 5 mode for now: the FSEvents C callback and the AppKit panels
            // need more isolation annotations than v1 is worth. Tighten later.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsherTests",
            dependencies: ["Usher"],
            path: "Tests/UsherTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

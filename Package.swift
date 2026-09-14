// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundcoreBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "soundcorectl", targets: ["soundcorectl"]),
    ],
    targets: [
        .executableTarget(
            name: "soundcorectl",
            path: "Sources/soundcorectl",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
    ]
)

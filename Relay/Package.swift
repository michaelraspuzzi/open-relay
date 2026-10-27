// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Embed Info.plist in the binary so `swift run` gets a bundle id and the mic/speech usage strings.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Relay",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(root)/Resources/Info.plist"]),
            ]),
    ]
)

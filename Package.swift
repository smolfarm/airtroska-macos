// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Airtroska",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Airtroska",
            path: "Sources/Airtroska"
        )
    ]
)
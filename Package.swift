// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Folio-PDFToolbox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Folio",
            path: "Sources/Folio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

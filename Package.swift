// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftSioyek",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        .library(name: "ReaderPersistence", targets: ["ReaderPersistence"]),
        .library(name: "PDFServices", targets: ["PDFServices"]),
        .executable(name: "ReaderDiagnostics", targets: ["ReaderDiagnostics"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: nil),
        .target(name: "ReaderCore"),
        .target(name: "ReaderPersistence", dependencies: ["ReaderCore", "CSQLite"]),
        .target(name: "PDFServices", dependencies: ["ReaderCore"]),
        .executableTarget(name: "ReaderDiagnostics", dependencies: ["ReaderCore", "ReaderPersistence", "PDFServices"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderIntegrationTests", dependencies: ["ReaderCore", "ReaderPersistence", "PDFServices"])
    ],
    swiftLanguageModes: [.v6]
)

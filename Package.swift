// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerfectNIO",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "PerfectNIOExe", targets: ["PerfectNIOExe"]),
        .library(name: "PerfectNIO", targets: ["PerfectNIO"]),
        .library(name: "PerfectNIOCRUD", targets: ["PerfectNIOCRUD"]),
        .library(name: "PerfectAdminConsole", targets: ["PerfectAdminConsole"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/taplin/Perfect-CRUD.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-MySQL.git", branch: "main"),
    ],
    targets: [
        // Local system library wrapping libz — replaces PerfectCZlib
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib"]),
                .apt(["zlib1g-dev"]),
            ]
        ),
        .executableTarget(
            name: "PerfectNIOExe",
            dependencies: ["PerfectNIO"]
        ),
        .target(
            name: "PerfectNIO",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                "CZlib",
            ]
        ),
        .target(
            name: "PerfectNIOCRUD",
            dependencies: [
                "PerfectNIO",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
                .product(name: "NIO", package: "swift-nio"),
            ]
        ),
        .target(
            name: "PerfectAdminConsole",
            dependencies: [
                "PerfectNIO",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "PerfectAdminConsoleTests",
            dependencies: [
                "PerfectAdminConsole",
                "PerfectNIO",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "PerfectNIOSmokeTests",
            dependencies: [
                "PerfectNIO",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "PerfectNIOMySQLTests",
            dependencies: [
                "PerfectNIO",
                "PerfectNIOCRUD",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
                .product(name: "PerfectMySQL", package: "Perfect-MySQL"),
            ]
        ),
    ]
)

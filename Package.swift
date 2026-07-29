// swift-tools-version: 6.2
import PackageDescription

// Local system library wrapping libz — replaces PerfectCZlib.
//
// No `pkgConfig` on macOS: recent CommandLineTools/Xcode SDKs bundle
// zlib's headers directly, and Clang finds them via its default system
// search path with zero extra flags. If a Homebrew zlib is *also* on
// PKG_CONFIG_PATH, asking pkg-config here can resolve to Homebrew's copy
// instead, mixing its headers with the SDK's in the same module build
// (the same "conflicting types" class of failure documented for libxml2
// in Perfect-XML/Perfect-Lasso's Documentation/libxml2-pkgconfig-collision.md).
// Linux has no bundled system copy, so pkg-config + apt stays required there.
#if os(macOS)
let czlibTarget: Target = .systemLibrary(name: "CZlib")
#else
let czlibTarget: Target = .systemLibrary(
    name: "CZlib",
    pkgConfig: "zlib",
    providers: [
        .apt(["zlib1g-dev"]),
    ]
)
#endif

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
        // Wide range (not `from:`) so this resolves alongside consumers pinning swift-crypto 4.x,
        // e.g. Perfect-Lasso's LassoPerfectSMTP -> Perfect-SMTP, which pins `exact: "4.5.1"`.
        // Insecure.SHA1.hash(data:) (the only API this target uses) is stable across 3.x/4.x.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/taplin/Perfect-CRUD.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-MySQL.git", branch: "main"),
    ],
    targets: [
        czlibTarget,
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

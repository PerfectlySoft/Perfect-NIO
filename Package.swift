// swift-tools-version:4.0

import PackageDescription

let package = Package(
	name: "PerfectNIO",
	products: [
		.executable(name: "PerfectNIOExe", targets: ["PerfectNIOExe"]),
		.library(name: "PerfectNIO", targets: ["PerfectNIO"]),
	],
	dependencies: [
//		.package(url: "https://github.com/PerfectlySoft/Perfect-Mustache.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/PerfectLib.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-SQLite.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CRUD.git", from: "1.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CURL.git", .branch("master")),
		.package(url: "https://github.com/apple/swift-nio.git", .branch("master")),
		.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "1.3.2"),
	],
	targets: [
		.target(name: "PerfectNIOExe", dependencies: ["PerfectNIO", "PerfectSQLite"]),
		.target(name: "PerfectNIO", dependencies: ["PerfectLib", "PerfectCRUD", "NIOHTTP1", "NIOOpenSSL"]),
		.testTarget(name: "PerfectNIOTests", dependencies: ["PerfectNIO", "PerfectSQLite", "PerfectCURL"]),
	]
)

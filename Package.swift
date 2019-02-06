// swift-tools-version:4.2

import PackageDescription

let package = Package(
	name: "PerfectNIO",
	products: [
		.executable(name: "PerfectNIOExe", targets: ["PerfectNIOExe"]),
		.library(name: "PerfectNIO", targets: ["PerfectNIO"]),
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/Perfect-Mustache.git", .branch("4.0-dev")),
		.package(url: "https://github.com/PerfectlySoft/PerfectLib.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CRUD.git", from: "1.0.0"),
		.package(url: "https://github.com/apple/swift-nio.git", from: "1.0.0"),
		.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "1.0.0"),
		
		// tests only
		.package(url: "https://github.com/PerfectlySoft/Perfect-CURL.git", .branch("master")),
		// ?
		.package(url: "https://github.com/PerfectlySoft/Perfect-SQLite.git", from: "3.0.0"),
	],
	targets: [
		.target(name: "PerfectNIOExe", dependencies: [
			"PerfectNIO",
			"PerfectSQLite"
			]),
		.target(name: "PerfectNIO", dependencies: [
			"PerfectLib",
			"PerfectCRUD",
			"PerfectMustache",
			"NIOHTTP1",
			"NIOOpenSSL",
			"NIOWebSocket"]),
		.testTarget(name: "PerfectNIOTests", dependencies: [
			"PerfectNIO",
			"PerfectSQLite",
			"PerfectCURL"]),
	]
)

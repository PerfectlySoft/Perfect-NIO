// swift-tools-version:5.1

import PackageDescription

let package = Package(
	name: "PerfectNIO",
	platforms: [
		.macOS(.v10_15)
	],
	products: [
		.executable(name: "PerfectNIOExe", targets: ["PerfectNIOExe"]),
		.library(name: "PerfectNIO", targets: ["PerfectNIO"]),
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/Perfect-Mustache.git", from: "4.0.0"),
		.package(url: "https://github.com/PerfectlySoft/PerfectLib.git", from: "4.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CRUD.git", from: "2.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-MIME.git", from: "1.0.0"),
		.package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
		.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CZlib-src.git", from: "0.0.0"),
		
		// tests only
		.package(url: "https://github.com/PerfectlySoft/Perfect-CURL.git", from: "5.0.0"),
	],
	targets: [
		.target(name: "PerfectNIOExe", dependencies: [
			"PerfectNIO",
		]),
		.target(name: "PerfectNIO", dependencies: [
			"PerfectLib",
			"PerfectCRUD",
			"PerfectMIME",
			"PerfectMustache",
			"NIOHTTP1",
			"NIOSSL",
			"NIOWebSocket",
			"PerfectCZlib"
		]),
		.testTarget(name: "PerfectNIOTests", dependencies: [
			"PerfectNIO",
			"PerfectCURL"
		]),
	]
)

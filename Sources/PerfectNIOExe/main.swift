
import PerfectNIO
import Foundation

let index = root {
	try FileOutput(localPath: "./webroot/index.html") as HTTPOutput
}

// Echoes text/binary back to the client; replies to close and pings explicitly (manualClose).
let socket = root().echo.webSocket(protocol: "echo", options: [.manualClose]) { _ -> WebSocketHandler in
	return { ws in
		loop: while true {
			let message: WebSocketMessage
			do {
				message = try await ws.readMessage()
			} catch {
				break loop
			}
			switch message {
			case .close:
				try? await ws.writeMessage(.close)
				break loop
			case .ping:
				try? await ws.writeMessage(.pong)
			case .pong:
				()
			case .text(let text):
				try? await ws.writeMessage(.text(text))
			case .binary(let binary):
				try? await ws.writeMessage(.binary(binary))
			}
		}
	}
}

let routes = try root().dir(index, socket)
try await Server(routes: routes, port: 42000).run()

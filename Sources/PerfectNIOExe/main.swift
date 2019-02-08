
import PerfectNIO

let index = root {
	try FileOutput(localPath: "./webroot/index.html") as HTTPOutput
}
class EchoSocket {
	var socket: WebSocket
	var closed = false
	init(socket: WebSocket) {
		self.socket = socket
		self.socket.options = [.manualClose]
	}
	deinit {
		print("death")
	}
	func process(message msg: WebSocketMessage) {
		switch msg {
		case .close:
			if !closed {
				_ = socket.writeMessage(.close)
			}
			closed = true
		case .ping:
			_ = socket.writeMessage(.pong)
		case .pong:
			()
		case .text(let text):
			_ = socket.writeMessage(.text(text))
		case .binary(let binary):
			_ = socket.writeMessage(.binary(binary))
		}
	}
	func loop() {
		guard !closed else {
			return
		}
		socket.readMessage().whenSuccess {
			msg in
			self.process(message: msg)
			self.loop()
		}
	}
}
let socket = root().echo.webSocket(protocol: "echo") {
	request -> WebSocketHandler in
	return {
		socket in
		EchoSocket(socket: socket).loop()
	}
}

let server = try root().dir(index, socket).bind(port: 42000).listen()
try server.wait()

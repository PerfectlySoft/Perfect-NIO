
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
	func loop() {
		socket.readMessage().whenSuccess {
			msg in
			switch msg {
			case .close:
				if !self.closed {
					_ = self.socket.writeMessage(.close)
				}
				self.closed = true
			case .ping:
				_ = self.socket.writeMessage(.pong)
			case .pong:
				()
			case .text(let text):
				_ = self.socket.writeMessage(.text(text))
			case .binary(let binary):
				_ = self.socket.writeMessage(.binary(binary))
			}
			if !self.closed {
				self.loop()
			}
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

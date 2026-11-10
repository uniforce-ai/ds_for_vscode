import Foundation
import Network

/// Loopback receiver for Codex hooks. The Linux host reaches it through SSH RemoteForward.
final class StatusServer {
    static let defaultPort: UInt16 = 8931

    var onEvent: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?
    private var listener: NWListener?
    private(set) var port: UInt16 = StatusServer.defaultPort

    func start(port: UInt16 = StatusServer.defaultPort) {
        stop()
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStatus?("端口无效")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onStatus?("监听 127.0.0.1:\(self.port)")
                case .failed(let error):
                    self.onStatus?("监听失败：\(error.localizedDescription)")
                case .cancelled:
                    self.onStatus?("已停止监听")
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            onStatus?("无法启动监听：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequestParser.parse(buffer) {
                self.respond(request, on: connection)
            } else if isComplete || error != nil || buffer.count > 1024 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(_ request: HTTPRequestParser.Request, on connection: NWConnection) {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let ok: Bool
        if request.method == "GET", path == "/health" {
            ok = true
        } else if request.method == "POST", path == "/event" {
            onEvent?(request.body)
            ok = true
        } else {
            ok = false
        }
        let status = ok ? "200 OK" : "404 Not Found"
        let body = ok ? "ok" : "no"
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

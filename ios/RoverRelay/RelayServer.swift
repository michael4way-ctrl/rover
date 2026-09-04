import Foundation
import Network

private struct IncomingRequest {
    let method: String
    let target: String
    let contentType: String?
    let body: Data

    static func parse(from data: Data) -> IncomingRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return nil }

        var contentLength = 0
        var contentType: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            } else if name == "content-type" {
                contentType = value
            }
        }

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        return IncomingRequest(
            method: String(parts[0]),
            target: String(parts[1]),
            contentType: contentType,
            body: body
        )
    }
}

final class RelayServer: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var listenerStatus = "Запускаю USB-посредник"
    @Published private(set) var lastEvent = "Жду первый запрос"
    @Published private(set) var requestCount = 0

    private let targetBase = "http://192.168.2.23"
    private let cameraBase = "http://192.168.2.24"
    private let cameraStreamBase = "http://192.168.2.24:81"
    private let port: NWEndpoint.Port = 17777
    private let queue = DispatchQueue(label: "com.ramchike.roverrelay.server")
    private var listener: NWListener?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let listener = try NWListener(using: .tcp, on: self.port)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.publishListenerState(state)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.publish(status: "Ошибка запуска", event: error.localizedDescription, listening: false)
            }
        }
    }

    func testStatus() {
        guard let url = URL(string: targetBase + "/status") else { return }
        publishEvent("Проверяю /status…")

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                self?.publishEvent("/status: \(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let preview = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\(data?.count ?? 0) байт"
            self?.publishEvent("/status: HTTP \(code) · \(preview.prefix(180))")
        }.resume()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            if let request = IncomingRequest.parse(from: nextBuffer) {
                self.forward(request, on: connection)
            } else if nextBuffer.count > 1_048_576 {
                self.respond(status: 413, contentType: "text/plain", body: Data("Request too large".utf8), on: connection)
            } else if error != nil || isComplete {
                self.respond(status: 400, contentType: "text/plain", body: Data("Invalid HTTP request".utf8), on: connection)
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func forward(_ incoming: IncomingRequest, on connection: NWConnection) {
        if incoming.method == "OPTIONS" {
            respond(status: 204, contentType: "text/plain", body: Data(), on: connection)
            return
        }

        guard incoming.target.hasPrefix("/"),
              let url = destinationURL(for: incoming.target),
              ["GET", "POST", "HEAD"].contains(incoming.method) else {
            respond(status: 400, contentType: "application/json", body: Data("{\"ok\":false,\"error\":\"unsupported request\"}".utf8), on: connection)
            return
        }

        RoverRequestGate.shared.waitForTurn()

        var request = URLRequest(url: url)
        request.httpMethod = incoming.method
        request.httpBody = incoming.body.isEmpty ? nil : incoming.body
        request.timeoutInterval = 4
        if let contentType = incoming.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        publishEvent("\(incoming.method) \(incoming.target)")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                let body = Data("{\"ok\":false,\"error\":\"\(self.jsonEscape(error.localizedDescription))\"}".utf8)
                self.respond(status: 502, contentType: "application/json", body: body, on: connection)
                self.publishEvent("Ошибка: \(error.localizedDescription)")
                return
            }

            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let body = data ?? Data()
            self.respond(status: status, contentType: type, body: body, on: connection)
            self.publishEvent("\(incoming.target): HTTP \(status), \(body.count) байт")
        }.resume()
    }

    private func destinationURL(for target: String) -> URL? {
        if target == "/snapshot" || target.hasPrefix("/snapshot?") ||
            target == "/flash" || target.hasPrefix("/flash?") {
            return URL(string: cameraBase + target)
        }
        if target == "/stream" || target.hasPrefix("/stream?") {
            return URL(string: cameraStreamBase + target)
        }
        return URL(string: targetBase + target)
    }

    private func respond(status: Int, contentType: String, body: Data, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Max-Age: 600\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func publishListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            publish(status: "USB-посредник запущен", event: "Слушаю порт \(port)", listening: true)
        case .failed(let error):
            publish(status: "Ошибка USB-посредника", event: error.localizedDescription, listening: false)
        case .cancelled:
            publish(status: "USB-посредник остановлен", event: "Соединение закрыто", listening: false)
        default:
            break
        }
    }

    private func publish(status: String, event: String, listening: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.listenerStatus = status
            self?.lastEvent = event
            self?.isListening = listening
        }
    }

    private func publishEvent(_ event: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastEvent = event
            self?.requestCount += 1
        }
    }

    private func jsonEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    /// Path without the query.
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        let components = URLComponents(string: target)
        path = components?.path ?? target
        query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        guard let body = try? IntegrationJSON.encoder().encode(value) else { return error(500, "Encoding failed") }
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }

    func serialized() -> Data {
        var headers = self.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        return data
    }
}

enum IntegrationJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A small HTTP/1.1 server bound to 127.0.0.1: one request per connection, with limits on
/// header and body size, open connections and the time a client has to send its request.
public final class LocalHTTPServer: @unchecked Sendable {
    public static let MAX_HEADER_BYTES = 16 * 1024
    public static let MAX_BODY_BYTES = 64 * 1024
    public static let MAX_CONNECTIONS = 16
    public static let REQUEST_TIMEOUT: TimeInterval = 5

    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "io.github.pieralukasz.echopad.http")
    private var listener: NWListener?
    private var openConnections = 0

    public init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    /// Starts listening on 127.0.0.1; port 0 picks a free one. Returns the bound port.
    public func start(port: UInt16) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        final class State: @unchecked Sendable { var error: Error? }
        let state = State()
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { update in
            switch update {
            case .ready: ready.signal()
            case .failed(let error):
                state.error = error
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        let timedOut = ready.wait(timeout: .now() + 5) == .timedOut
        if timedOut || state.error != nil {
            listener.cancel()
            throw state.error ?? POSIXError(.ETIMEDOUT)
        }
        self.listener = listener
        return listener.port?.rawValue ?? port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard openConnections < Self.MAX_CONNECTIONS, Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        openConnections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting: connection.cancel()
            case .cancelled: self?.openConnections -= 1
            default: break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.REQUEST_TIMEOUT, execute: timeout)
        receive(connection, buffer: Data(), timeout: timeout)
    }

    private func receive(_ connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { return connection.cancel() }
                self.receive(connection, buffer: buffer, timeout: timeout)
            case .failed(let response):
                timeout.cancel()
                Self.send(response, on: connection)
            case .complete(let request):
                timeout.cancel()
                let handler = self.handler
                Task { Self.send(await handler(request), on: connection) }
            }
        }
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    enum ParseResult {
        case incomplete
        case complete(HTTPRequest)
        case failed(HTTPResponse)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > MAX_HEADER_BYTES ? .failed(.error(431, "Request headers too large")) : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= MAX_HEADER_BYTES else { return .failed(.error(431, "Request headers too large")) }
        guard let head = String(data: buffer[buffer.startIndex ..< end.lowerBound], encoding: .utf8) else {
            return .failed(.error(400, "Bad request"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            return .failed(.error(400, "Bad request"))
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failed(.error(400, "Bad header")) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .failed(.error(501, "Chunked bodies are not supported")) }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return .failed(.error(400, "Bad Content-Length"))
        }
        guard length <= MAX_BODY_BYTES else { return .failed(.error(413, "Request body too large")) }
        guard buffer.endIndex - end.upperBound >= length else { return .incomplete }
        let body = Data(buffer[end.upperBound ..< end.upperBound + length])
        return .complete(HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body))
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}

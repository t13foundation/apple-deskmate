import Foundation
import MCP
import Network

struct FixtureRequest: Sendable {
    let method: String
    let path: String
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data
}

struct FixtureResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Turns an SDK response into a plain one. Event streams from POST requests end after the reply, so they are
    /// collected and sent with a known length.
    init(collecting response: HTTPResponse) async {
        self.status = response.statusCode
        self.headers = response.headers
        switch response {
        case .stream(let stream, _):
            var collected = Data()
            do {
                for try await chunk in stream { collected.append(chunk) }
            } catch {
                // A failed stream ends the reply early.
            }
            self.body = collected
        default:
            self.body = response.bodyData ?? Data()
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var merged = headers
        merged["Content-Length"] = String(body.count)
        merged["Connection"] = "close"
        merged["Cache-Control"] = "no-store"
        for (name, value) in merged.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 307: "Temporary Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

/// One accepted TCP connection: reads a single HTTP/1.1 request and writes a single response.
final class FixtureConnection: @unchecked Sendable {
    enum ReadError: Error {
        case tooLarge
        case malformed
    }

    private let connection: NWConnection
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1024 * 1024

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.start(queue: queue)
    }

    func close() {
        connection.cancel()
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func readRequest() async throws -> FixtureRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = try await receiveChunk() else { return nil }
            buffer.append(chunk)
            headerEnd = buffer.range(of: separator)
            if headerEnd == nil, buffer.count > Self.maxHeaderBytes { throw ReadError.tooLarge }
        }
        guard let headerEnd, let headText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ReadError.malformed
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw ReadError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maxBodyBytes else { throw ReadError.tooLarge }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            guard let chunk = try await receiveChunk() else { throw ReadError.malformed }
            body.append(chunk)
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return FixtureRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body.prefix(length))
    }
}

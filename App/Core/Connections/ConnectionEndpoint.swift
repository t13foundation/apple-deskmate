import Foundation

/// A validated MCP endpoint. Only values created through `validate` exist, so holders never re-check the scheme.
public struct ConnectionEndpoint: Sendable, Hashable, Codable {
    public let url: URL

    /// True when the endpoint is plain HTTP to this Mac. Shown to the user as a local development connection.
    public let isLoopbackDevelopment: Bool

    public var host: String { url.host(percentEncoded: false) ?? "" }

    /// The text used in "This connection sends data to {host}".
    public var displayHost: String {
        if let port = url.port, isLoopbackDevelopment || port != 443 {
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
        return host.contains(":") ? "[\(host)]" : host
    }

    private init(url: URL, isLoopbackDevelopment: Bool) {
        self.url = url
        self.isLoopbackDevelopment = isLoopbackDevelopment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        self = try Self.validate(text).get()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }

    public enum Problem: Error, Sendable, Equatable {
        case empty
        case malformed
        case unsupportedScheme(String)
        case insecureRemoteHTTP
        case missingHost
        case credentialsInURL
        case fragment

        public var message: String {
            switch self {
            case .empty:
                "Enter the address of the MCP service."
            case .malformed:
                "That address is not a valid web address."
            case .unsupportedScheme(let scheme):
                "Only https:// addresses are supported (found \(PlainText.sanitizeLine(scheme, limit: 20)):)."
            case .insecureRemoteHTTP:
                "Plain http:// is only allowed for this Mac (localhost, 127.0.0.1 or ::1). Use an https:// address."
            case .missingHost:
                "The address needs a host name, for example https://example.com/mcp."
            case .credentialsInURL:
                "Do not put a user name or password in the address. Use the token field instead."
            case .fragment:
                "Remove the # part from the address."
            }
        }
    }

    public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// HTTPS anywhere; HTTP only for explicit loopback development. No other schemes, no embedded credentials.
    public static func validate(_ text: String) -> Result<ConnectionEndpoint, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0 != " " }) else {
            return .failure(.malformed)
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.malformed)
        }
        guard scheme == "https" || scheme == "http" else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard components.user == nil, components.password == nil else { return .failure(.credentialsInURL) }
        guard components.fragment == nil else { return .failure(.fragment) }
        guard var host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let isLoopback = loopbackHosts.contains(host)
        if scheme == "http", !isLoopback { return .failure(.insecureRemoteHTTP) }
        guard let url = components.url else { return .failure(.malformed) }
        return .success(ConnectionEndpoint(url: url, isLoopbackDevelopment: scheme == "http" && isLoopback))
    }
}

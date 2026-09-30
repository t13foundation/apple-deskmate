import Foundation
import MCP

/// What the network layer observed. Produced by the bounded transport; translated to `ConnectionFailure` for people.
enum TransportFailure: Error, Sendable, Equatable {
    case http(status: Int)
    case oversized
    case redirectRefused
    case timeout
    case invalidResponse
    case protocolMismatch(String)
    case closed
}

/// An actionable problem with a connection or a tool call. Text never contains a token, a header or request content.
public struct ConnectionFailure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unauthorized
        case forbidden
        case notFound
        case network
        case timeout
        case tls
        case insecureBlocked
        case protocolMismatch
        case oversized
        case redirect
        case server
        case invalidResponse
        case missingToken
        case disconnected
        case notConnected
        case toolNotEnabled
        case connectionDisabled
        case unsupportedTool
        case invalidArguments
        case toolChanged
        case cancelled
        case invalidInput
        case storage
        case unknown
    }

    public let kind: Kind
    /// What happened, in one sentence.
    public let summary: String
    /// What the person can do about it.
    public let recovery: String

    public var message: String { recovery.isEmpty ? summary : "\(summary) \(recovery)" }

    public init(kind: Kind, summary: String, recovery: String) {
        self.kind = kind
        self.summary = summary
        self.recovery = recovery
    }

    // MARK: Mapping

    /// Translates any error from the transport or the SDK. `host` is shown to the person; `redactor` removes secrets
    /// from anything the server said.
    static func map(_ error: Error, host: String, redactor: Redactor) -> ConnectionFailure {
        if let failure = error as? ConnectionFailure { return failure }
        if let failure = error as? TransportFailure { return map(failure, host: host) }
        if error is CancellationError { return .disconnected(host: host) }
        if let urlError = error as? URLError { return map(urlError, host: host) }
        if let mcp = error as? MCPError { return map(mcp, host: host, redactor: redactor) }
        return ConnectionFailure(
            kind: .unknown,
            summary: "Something unexpected went wrong talking to \(host).",
            recovery: "Try again. If it keeps happening, disconnect and reconnect."
        )
    }

    private static func map(_ failure: TransportFailure, host: String) -> ConnectionFailure {
        switch failure {
        case .http(let status):
            switch status {
            case 401:
                return ConnectionFailure(
                    kind: .unauthorized,
                    summary: "\(host) did not accept the sign-in (HTTP 401).",
                    recovery: "Check that the token is correct and still valid, then edit the connection and enter it again."
                )
            case 403:
                return ConnectionFailure(
                    kind: .forbidden,
                    summary: "\(host) refused access (HTTP 403).",
                    recovery: "The token may lack permission for this service. Ask the service owner or use a different token."
                )
            case 404:
                return ConnectionFailure(
                    kind: .notFound,
                    summary: "\(host) has no MCP service at that address (HTTP 404).",
                    recovery: "Check the path in the address. MCP endpoints often end in /mcp."
                )
            case 408, 504:
                return map(.timeout, host: host)
            case 500...599:
                return ConnectionFailure(
                    kind: .server,
                    summary: "\(host) reported a server problem (HTTP \(status)).",
                    recovery: "Try again later. If it persists, contact the service owner."
                )
            default:
                return ConnectionFailure(
                    kind: .invalidResponse,
                    summary: "\(host) answered with an unexpected status (HTTP \(status)).",
                    recovery: "Check that the address points to an MCP service that uses Streamable HTTP."
                )
            }
        case .oversized:
            return ConnectionFailure(
                kind: .oversized,
                summary: "\(host) sent a reply larger than DeskMate accepts.",
                recovery: "The connection was stopped to protect your Mac. Use a service that returns smaller replies."
            )
        case .redirectRefused:
            return ConnectionFailure(
                kind: .redirect,
                summary: "\(host) tried to send DeskMate to another address.",
                recovery: "DeskMate does not follow redirects. Enter the final address of the service instead."
            )
        case .timeout:
            return ConnectionFailure(
                kind: .timeout,
                summary: "\(host) did not answer in time.",
                recovery: "Check your network and that the service is running, then try again."
            )
        case .invalidResponse:
            return ConnectionFailure(
                kind: .invalidResponse,
                summary: "\(host) replied in a way DeskMate cannot read as MCP.",
                recovery: "Check that the address points to an MCP service that uses Streamable HTTP."
            )
        case .protocolMismatch(let version):
            let shown = PlainText.sanitizeLine(version, limit: 24)
            return ConnectionFailure(
                kind: .protocolMismatch,
                summary: "\(host) requires MCP version “\(shown)”, which DeskMate does not support.",
                recovery: "DeskMate supports \(Self.supportedVersionsText). Ask the service owner for a compatible version."
            )
        case .closed:
            return .disconnected(host: host)
        }
    }

    private static func map(_ error: URLError, host: String) -> ConnectionFailure {
        switch error.code {
        case .timedOut:
            return map(.timeout, host: host)
        case .cancelled:
            return .disconnected(host: host)
        case .cannotFindHost, .dnsLookupFailed:
            return ConnectionFailure(
                kind: .network,
                summary: "DeskMate could not find \(host).",
                recovery: "Check the spelling of the address and your network connection."
            )
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
            .internationalRoamingOff, .dataNotAllowed:
            return ConnectionFailure(
                kind: .network,
                summary: "DeskMate could not reach \(host).",
                recovery: "Check that the service is running and that this Mac is online, then try again."
            )
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired:
            return ConnectionFailure(
                kind: .tls,
                summary: "The secure connection to \(host) could not be trusted.",
                recovery: "The certificate is invalid, expired or unknown to this Mac. DeskMate will not connect without a trusted certificate."
            )
        case .appTransportSecurityRequiresSecureConnection:
            return ConnectionFailure(
                kind: .insecureBlocked,
                summary: "macOS blocked a plain http:// connection to \(host).",
                recovery: "Use an https:// address. Plain http:// works only for localhost development builds that allow it."
            )
        case .dataLengthExceedsMaximum:
            return map(.oversized, host: host)
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return map(.redirectRefused, host: host)
        default:
            return ConnectionFailure(
                kind: .network,
                summary: "The connection to \(host) failed.",
                recovery: "Check your network and that the service is running, then try again."
            )
        }
    }

    private static func map(_ error: MCPError, host: String, redactor: Redactor) -> ConnectionFailure {
        switch error {
        case .transportError(let inner):
            return map(inner, host: host, redactor: redactor)
        case .connectionClosed:
            return .disconnected(host: host)
        case .internalError(let detail) where detail == "Client disconnected":
            return .disconnected(host: host)
        case .serverError(_, let message):
            return serverSaid(message, host: host, redactor: redactor)
        case .invalidParams(let message):
            return serverSaid(message, host: host, redactor: redactor)
        case .methodNotFound, .invalidRequest, .parseError, .internalError, .urlElicitationRequired:
            return ConnectionFailure(
                kind: .invalidResponse,
                summary: "\(host) does not support this request.",
                recovery: "Check that the service is an MCP server with tools."
            )
        }
    }

    private static func serverSaid(_ message: String?, host: String, redactor: Redactor) -> ConnectionFailure {
        let excerpt = PlainText.sanitizeLine(redactor.redact(message ?? ""), limit: 160)
        let said = excerpt.isEmpty ? "" : " It said: “\(excerpt)”."
        return ConnectionFailure(
            kind: .server,
            summary: "\(host) rejected the request.\(said)",
            recovery: "The message comes from the service and is not verified by DeskMate."
        )
    }

    static func disconnected(host: String) -> ConnectionFailure {
        ConnectionFailure(
            kind: .disconnected,
            summary: "The connection to \(host) was closed.",
            recovery: "Connect again to keep using it."
        )
    }

    static var supportedVersionsText: String {
        Version.supported.sorted().joined(separator: ", ")
    }

    // MARK: Fixed failures used by the manager

    static func notConnected(host: String) -> ConnectionFailure {
        ConnectionFailure(
            kind: .notConnected,
            summary: "This connection is not active.",
            recovery: "Open Connections and connect to \(host) first."
        )
    }

    static func connectionDisabled() -> ConnectionFailure {
        ConnectionFailure(
            kind: .connectionDisabled,
            summary: "This connection is turned off.",
            recovery: "Turn it on in Connections to use its tools."
        )
    }

    static func toolNotEnabled(_ name: String) -> ConnectionFailure {
        ConnectionFailure(
            kind: .toolNotEnabled,
            summary: "The tool “\(PlainText.sanitizeLine(name, limit: 40))” is not enabled.",
            recovery: "Enable it in Connections before it can be used."
        )
    }

    static func unsupportedTool(_ name: String) -> ConnectionFailure {
        ConnectionFailure(
            kind: .unsupportedTool,
            summary: "The tool “\(PlainText.sanitizeLine(name, limit: 40))” uses an input format DeskMate cannot check.",
            recovery: "It cannot be used."
        )
    }

    static func toolChanged(_ name: String) -> ConnectionFailure {
        ConnectionFailure(
            kind: .toolChanged,
            summary: "The service changed the tool “\(PlainText.sanitizeLine(name, limit: 40))” after you enabled it.",
            recovery: "Review the tool in Connections and enable it again if you still trust it."
        )
    }

    static func invalidArguments(_ error: ToolArgumentError) -> ConnectionFailure {
        ConnectionFailure(
            kind: .invalidArguments,
            summary: "The tool inputs were not valid, so nothing was sent.",
            recovery: error.message
        )
    }

    static var missingToken: ConnectionFailure {
        ConnectionFailure(
            kind: .missingToken,
            summary: "The token for this connection is missing from the Keychain.",
            recovery: "Edit the connection and enter the token again."
        )
    }

    static func invalidInput(_ message: String) -> ConnectionFailure {
        ConnectionFailure(kind: .invalidInput, summary: message, recovery: "")
    }

    static func storage(_ message: String) -> ConnectionFailure {
        ConnectionFailure(kind: .storage, summary: message, recovery: "")
    }

    static var cancelled: ConnectionFailure {
        ConnectionFailure(kind: .cancelled, summary: "The request was cancelled.", recovery: "")
    }
}

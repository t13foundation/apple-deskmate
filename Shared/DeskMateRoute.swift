import Foundation

/// A place in the app that a widget tap or a link may open. A URL is untrusted input, so only these exact shapes parse:
///
///     deskmate://ask
///     deskmate://new
///     deskmate://files
///     deskmate://resume?id=<conversation UUID>
///
/// Anything else (another scheme, an unknown host, a path, a port, credentials, a fragment, extra or repeated query
/// items, a malformed ID) is rejected and the app does nothing with it.
public enum DeskMateRoute: Equatable, Sendable {
    case ask
    case new
    case files
    case resume(UUID)

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DeskMateShared.urlScheme,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased()
        else { return nil }
        let items = components.queryItems ?? []
        switch host {
        case "ask", "new", "files":
            guard items.isEmpty else { return nil }
            switch host {
            case "ask": self = .ask
            case "new": self = .new
            default: self = .files
            }
        case "resume":
            guard items.count == 1, items[0].name == "id",
                  let value = items[0].value, value.count == 36, let id = UUID(uuidString: value)
            else { return nil }
            self = .resume(id)
        default:
            return nil
        }
    }

    /// The link a widget or menu uses to reach this route.
    public var url: URL {
        var components = URLComponents()
        components.scheme = DeskMateShared.urlScheme
        switch self {
        case .ask: components.host = "ask"
        case .new: components.host = "new"
        case .files: components.host = "files"
        case .resume(let id):
            components.host = "resume"
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        }
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

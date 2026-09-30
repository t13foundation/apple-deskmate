import DeskMateCore
import Observation

enum AppSection: Hashable {
    case chat
    case files
    case connections
}

/// Which screen is showing and which cited excerpt the source drawer displays.
@MainActor
@Observable
final class AppNavigation {
    var section: AppSection = .chat
    /// The excerpt shown in the source drawer. Nil closes the drawer.
    var viewedCitation: SourceCitation?

    func show(_ citation: SourceCitation) {
        viewedCitation = citation
    }

    func closeViewer() {
        viewedCitation = nil
    }
}

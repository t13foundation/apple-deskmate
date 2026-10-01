import SwiftUI
import WidgetKit

/// Entry point of the widget extension. WidgetKit loads this bundle in its own process; there is no app code,
/// model, network or conversation here.
@main
struct DeskMateWidgetBundle: WidgetBundle {
    var body: some Widget {
        DeskMateWidget()
    }
}

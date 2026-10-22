import AppKit
import DeskMateCore
import SwiftUI

extension DS.Layout {
    /// Ideal width of the Review tool call sheet, with the narrowest and widest it may take.
    static let approvalSheetWidth: CGFloat = 520
    static let approvalSheetMinWidth: CGFloat = 460
    static let approvalSheetMaxWidth: CGFloat = 680
}

/// Shows the oldest waiting tool call and nothing else can answer it: only these two buttons (or Escape, which denies)
/// resolve the request. There is no "always allow", the sheet cannot be dismissed any other way, and Return does not
/// allow. Keyboard focus starts on Deny so a stray key press never sends anything. Allow has no key equivalent at all:
/// it takes a click, or Tab to it and Space. The inputs scroll in the middle; the title and the buttons stay in view.
struct ToolApprovalModifier: ViewModifier {
    let broker: ToolApprovalBroker
    /// With the main window and the compact panel both on screen, only one of them presents the sheet.
    @Environment(\.presentsConversationSheets) private var presents

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { presents ? broker.pending : nil },
                // The sheet cannot be dismissed from outside; only the buttons below answer a request.
                set: { _ in }
            )
        ) { request in
            ToolApprovalSheet(request: request, waiting: broker.queue.count, broker: broker)
                .id(request.id)
                .interactiveDismissDisabled(true)
        }
    }
}

extension View {
    /// Presents the Review tool call sheet whenever a connected-service call waits for an answer.
    func toolApprovalSheet(broker: ToolApprovalBroker) -> some View {
        modifier(ToolApprovalModifier(broker: broker))
    }
}

struct ToolApprovalSheet: View {
    let request: ToolApprovalRequest
    let waiting: Int
    let broker: ToolApprovalBroker

    @State private var descriptionExpanded = false
    @State private var contentHeight: CGFloat = 240
    @FocusState private var denyFocused: Bool

    private var preview: ToolCallPreview { request.preview }

    /// The tallest the whole sheet may be: the smaller of the window it opens over and the screen, with a margin.
    /// Long inputs scroll inside this; the title and the two buttons never leave the sheet.
    private var maxSheetHeight: CGFloat {
        let window = NSApp.keyWindow?.frame.height ?? .greatestFiniteMagnitude
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, min(window, screen) - 80)
    }

    /// What is left for the scrolling part after the title block and the action bar.
    private var scrollAreaCap: CGFloat { max(160, maxSheetHeight - Self.fixedChromeHeight) }

    /// Rough height of the title block plus the action bar and its divider.
    private static let fixedChromeHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Review tool call")
                    .font(.dmTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("DeskMate wants to ask a connected service. Nothing is sent unless you allow it.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                if waiting > 1 {
                    Text("\(waiting - 1) more \(waiting == 2 ? "request is" : "requests are") waiting after this one.")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.top, .horizontal], DS.Spacing.panel)

            // The facts, the exact inputs and the data-flow sentence scroll together, so a long input never pushes the
            // buttons off screen and everything that will be sent can still be read in full.
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    facts
                    inputs
                    dataFlow
                    serviceDescription
                }
                .padding(DS.Spacing.panel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, scrollAreaCap))

            Divider()

            HStack {
                Spacer()
                Button("Deny", role: .cancel) {
                    broker.deny(request.id)
                    Announcer.post("Denied. Nothing was sent.")
                }
                .keyboardShortcut(.cancelAction)
                .focused($denyFocused)
                .accessibilityHint("Declines this call. Nothing is sent.")
                Button("Allow once") {
                    broker.allowOnce(request.id)
                    Announcer.post("Allowed once.")
                }
                .accessibilityHint("Sends the inputs shown to \(preview.host), this one time")
            }
            .controlSize(.large)
            .padding(DS.Spacing.panel)
        }
        .frame(minWidth: DS.Layout.approvalSheetMinWidth, idealWidth: DS.Layout.approvalSheetWidth, maxWidth: DS.Layout.approvalSheetMaxWidth)
        .onAppear {
            denyFocused = true
            Announcer.post("Review tool call. \(preview.toolName) on \(preview.host). Allow or deny.")
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
            fact("Connection", preview.connectionName)
            fact("Address", preview.url)
            fact("Tool", preview.toolName)
        }
        .accessibilityElement(children: .contain)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.dmBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Exact inputs")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if preview.arguments.isEmpty {
                    Text("None")
                        .font(.dmBody)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preview.arguments) { argument in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                            Text(argument.name)
                                .font(.dmCaption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(argument.value)
                                .font(.system(size: DS.FontSize.body, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(Color.dmSubtleFill)
            )
        }
    }

    private var dataFlow: some View {
        Label {
            Text(preview.dataFlow)
                .font(.dmBody)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(Color.dmBrandText)
                .frame(width: DS.Layout.iconWidth)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var serviceDescription: some View {
        if !preview.serverDescription.isEmpty {
            DMDisclosure(
                isExpanded: $descriptionExpanded,
                label: "What the service says this tool does, not verified",
                hint: "Shows the description the service gave for this tool. It is the service's own claim."
            ) {
                Text("What the service says this tool does (not verified)")
                    .font(.dmCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } content: {
                Text(preview.serverDescription)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, DS.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

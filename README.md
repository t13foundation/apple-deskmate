# DeskMate

A calm, native macOS assistant that answers questions using model knowledge, selected files, and approved MCP tools using Apple’s on-device model.

## Product

English interface and English material processing. A desktop widget, global shortcut, and menu bar open a compact conversational assistant panel. Selected folders form a local searchable library. Optional MCP connections let the assistant retrieve explicitly approved context from a configured service.

- [Canonical product specification](docs/specyfikacja-produktowa.md) (Polish)
- [Design system](docs/design-system.md)
- [Delivery Project](https://github.com/orgs/t13foundation/projects/10)
- [Prototype work packages](https://github.com/t13foundation/apple-deskmate/issues)

## Current state

Planning only. There is no application implementation, build target, or installable release yet. All planned work starts in Backlog; the requested delivery is the complete prototype; implementation has not started.

## Intended runtime

macOS 26 or later, an Apple Intelligence-compatible Mac, and an available on-device SystemLanguageModel. Swift, SwiftUI, Foundation Models, WidgetKit, App Intents, and the official MCP Swift SDK. No paid model API or macOS 27 upgrade is required for the initial scope.

Full Xcode with the matching macOS SDK is needed to build the application and widget extension. Apple Intelligence availability and English support must be checked at runtime. Exact signing and App Group provisioning requirements must be proved on the target Mac in the widget work package; possession of a Developer Program membership is not assumed.

Use synthetic English samples for demonstrations. MCP can transmit data outside the Mac; connecting a server is a separate trust decision.

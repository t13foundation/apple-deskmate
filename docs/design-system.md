# DeskMate design system

## Experience

A calm desktop companion for focused work. The interface must make input, output, and the next action obvious. Use native SwiftUI controls, SF Pro system typography, and SF Symbols; do not imitate a web dashboard.

## Foundations

- Spacing: 4, 8, 12, 16, 24, 32 pt. Primary panel padding: 20 pt.
- Corners: 10 pt controls, 16 pt grouped surfaces, 22 pt compact panel.
- Colors: semantic macOS text/background colors, the T13 brand violet as the accent (brand-fill `oklch(0.496 0.265 302)` light and `oklch(0.558 0.288 302)` dark for primary fills and selection, with white on it; brand-text `oklch(0.45 0.22 302)` light and `oklch(0.76 0.16 305)` dark for accent text, icons and focus; built in Display P3; the lime highlight is not a general accent), semantic warning/error colors. Meet contrast in light/dark and increased-contrast modes.
- Type: title 24 pt semibold, section 16 pt semibold, body 14 pt, supporting text 12 pt minimum. Support accessibility settings without clipping.
- Materials: subtle native window/sidebar material where readable; solid alternative for Reduce Transparency. One clear focal area; minimal chrome.
- Motion: short purposeful transitions, never perpetual animation. Respect Reduce Motion.

## Main window

A restrained sidebar (New chat, Recent, My files, Connections, Settings), conversation, composer, attachment strip, and source drawer. The primary interaction is asking a question with follow-ups. Starter prompts: Ask about my files, Summarize a meeting, Compare documents. Responses render readable Markdown with expandable citations and tool activity; generated briefs have a separate editable result view. Avoid duplicating a chat and a task dashboard.

## Compact panel and widget

The compact assistant panel opens in the current workspace, starts around 460 × 560 pt, grows or opens the main window for long results, and supports Escape, keyboard focus, pin/unpin, and a clear return path. Pin means the panel remains visible while other apps are active; it must not unexpectedly steal focus or block full-screen applications.

Small desktop widget: brand mark, generic model readiness, Ask DeskMate action. Medium widget: New chat, Ask my files, and Resume links and generic latest-task status. No text field or drag target is promised inside WidgetKit. Clicking opens the corresponding app panel. Default widget content never reveals a document title or result. No fake live progress: display the time of the last snapshot when needed.

## States and copy

Every key surface has a useful empty state, loading/cancel state, recoverable error, completed result, and disabled state. Explain unavailable model, unsupported file, oversize input, disconnected connector, denied tool, and expired credential with a next step.

Examples: “What would you like to work on?” / “Add material” / “Create a brief” / “Working on your Mac” / “Review tool call” / “This connection sends data to {host}”. Never claim fully local processing when MCP is remote.

## Acceptance

A nonprogrammer can complete the main task without instructions. Validate real screenshot composition at compact and expanded sizes in light/dark themes, tab order, visible focus, VoiceOver labels, text wrapping, and reduced motion/transparency. Visual quality is part of each delivery, starting with the first slice.

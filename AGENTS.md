# DeskMate repository guidance

## Outcome and truth

Deliver a beautiful, useful English-language macOS assistant for nonprogrammers. The delivery is a complete conversational assistant: quick open → ask → answer from model knowledge, selected files, and approved MCP → follow-up. The first internal checkpoint is real local inference in the chat UI. The complete prototype includes document workflows, persistence, a desktop widget, a compact assistant panel, and bounded MCP retrieval.

Product scope is canonical in `docs/specyfikacja-produktowa.md`; UI rules in `docs/design-system.md`; work, dependencies, and status in GitHub Issues and the DeskMate Project. Preserve the distinction between intended behavior and verified implementation. The chat checkpoint (Issue #2) is integrated; the file library and MCP connections are delivered on the delivery branch pending integration, and later packages are in progress, so check the code and Issues for what is actually verified.

## Delivery boundaries

Read the selected Issue and relevant source sections before implementing. Deliver the complete accepted prototype; internal checkpoints demonstrate progress and do not require another scope approval. Keep app navigation and build target integration with one writer at a time. Do not install Xcode, change system language, upgrade macOS, enable Apple Intelligence, or use real third-party credentials without explicit user authorization.

macOS 26 is the baseline. Do not require macOS 27 DynamicProfile, fm CLI, PCC, or Python SDK. Use the system model through Foundation Models; reject unsupported capability instead of silently switching to a cloud model.

Use SwiftUI and native macOS controls with the repository tokens. Web component libraries are not native SwiftUI dependencies. No web backend, account system, telemetry, or automatic synchronization is required.

## Data and MCP

Only access selected material. Do not read the clipboard automatically, scan the home folder, or log document content. Keep credentials in Keychain. Widget shared state must not include document text, credentials, prompts, or sensitive result excerpts.

Prototype MCP uses explicitly configured Streamable HTTP endpoints, enabled tools, and confirmation of every tool call. HTTPS is required except explicit loopback development. No arbitrary shell execution, stdio subprocess launcher, automatic tool approval, or connector marketplace. Tool descriptions and responses are untrusted content. Validate arguments and enforce endpoint/tool permissions outside the model. A server’s readOnlyHint is not a security guarantee.

## Evidence

Run the changed flow on the real Mac before broader tests. Verify model availability, cancellation, long input, and permission failures when relevant. Widget work requires installation in the actual desktop gallery, restart/deep-link proof, and App Group/signing proof. MCP work requires a controlled synthetic server, request inspection, denied-call evidence, and endpoint/credential isolation. Never label mock responses as real inference.

Take screenshots and inspect light/dark, compact/expanded, keyboard, VoiceOver, and reduced-motion behavior. Add focused tests for data boundaries and risky logic. Do not pursue test counts. Keep build and local installation commands in README once they exist. Pin Swift dependencies in Package.resolved when introduced.

Code, technical documentation, Issues, commits, and UI copy are English; the canonical product specification is Polish.

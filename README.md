# DeskMate

A calm, native macOS assistant that answers questions using model knowledge, selected files, and approved MCP tools using Apple’s on-device model.

## Product

English interface and English material processing. A desktop widget, global shortcut, and menu bar open a compact conversational assistant panel. Selected folders form a local searchable library. Optional MCP connections let the assistant retrieve explicitly approved context from a configured service.

- [Canonical product specification](docs/specyfikacja-produktowa.md) (Polish)
- [Design system](docs/design-system.md)
- [Delivery Project](https://github.com/orgs/t13foundation/projects/10)
- [Prototype work packages](https://github.com/t13foundation/apple-deskmate/issues)

## Current state

Implemented so far (work package WBS-PROT-01, Issue #2): a native SwiftUI chat window backed by Apple’s on-device model through Foundation Models. It has a streaming answer, Stop, follow-ups that share one model session, New chat that clears the model context, selectable Markdown answers, a model-readiness banner, and recoverable states for empty input, an unavailable model, guardrail and other errors, and the context limit. The question and the composer text are never lost.

Not implemented yet: library, MCP, persistence, widget, compact panel, global shortcut, menu bar. See the Issues.

Verified on the target Mac (Apple M5, macOS 26.6.1): the package builds with Command Line Tools and the 38 focused tests pass. Real inference has **not** been verified: on the target Mac Apple Intelligence is off, so `--diagnose-model` reports `unavailable (appleIntelligenceNotEnabled)`. The app shows that state honestly and never substitutes another model or mock text.

## Build, test and run

Requires macOS 26 and Swift 6.2 or later. Command Line Tools are enough; full Xcode is not required for this package.

```sh
swift build -c release            # compile
bash scripts/test.sh              # focused tests (see the note below)
swift run DeskMate                # open the app window from the terminal
swift run DeskMate --diagnose-model   # print model readiness and exit (0 ready, 3 not ready)
swift run DeskMate --ask "What is a budget?"   # one real on-device generation; refuses if the model is not ready
bash scripts/build-app.sh         # assemble and ad-hoc sign dist/DeskMate.app (sandboxed)
open dist/DeskMate.app
```

`scripts/test.sh` exists because with only Command Line Tools selected, plain `swift test` cannot find the Testing framework: it either fails to compile (`no such module 'Testing'`) or builds and runs zero tests. The script reads the developer directory from `$DEVELOPER_DIR` (else `xcode-select -p`), adds the framework path only for Command Line Tools, fails if no tests ran, and is plain `swift test` under full Xcode.

Two toolchains are supported and the deployment target stays macOS 26 for both: Command Line Tools (macOS 26.5 SDK, the global selection) and Xcode 27.0 (27A266a), used without changing `xcode-select`:

```sh
export DEVELOPER_DIR=/Users/marekwolansky/Downloads/Xcode.app/Contents/Developer   # example path
swift build -c release
bash scripts/test.sh
bash scripts/build-app.sh
```

These three commands are run by the host with Xcode 27.0. Not executed yet as of this change: `swift build -c release` and `scripts/build-app.sh` with Xcode 27.0 and `scripts/test.sh` with either toolchain after the `DEVELOPER_DIR` change. The Xcode 27 SDK is also what surfaced the non-exhaustive `switch` warnings fixed in `SystemModelEngine.swift`.

Do not use macOS 27 APIs; the code must compile warning-free against both SDKs.

`scripts/build-app.sh` signs ad-hoc (`--sign -`) with `App/Resources/DeskMate.entitlements` (App Sandbox only for now). Ad-hoc signing is enough to run on this Mac. The widget’s App Group needs a real team identity and is handled in the widget package.

The app writes no logs. `--diagnose-model` prints readiness only; `--ask` prints the answer to your terminal because you asked for it.

## Intended runtime

macOS 26 or later, an Apple Intelligence-compatible Mac, and an available on-device SystemLanguageModel. Swift, SwiftUI, Foundation Models, WidgetKit, App Intents, and the official MCP Swift SDK. No paid model API or macOS 27 upgrade is required for the initial scope.

Turn on Apple Intelligence in System Settings before asking a question; the app opens that pane on request but never changes the setting. Apple Intelligence availability and English support are checked at runtime. Full Xcode with the matching macOS SDK is expected for the widget extension and its signing; exact signing and App Group provisioning requirements must be proved on the target Mac in the widget work package. Possession of a Developer Program membership is not assumed.

Use synthetic English samples for demonstrations. MCP can transmit data outside the Mac; connecting a server is a separate trust decision.

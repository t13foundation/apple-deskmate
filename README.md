# DeskMate

A calm, native macOS assistant that answers questions using model knowledge, selected files, and approved MCP tools using Apple’s on-device model.

## Product

English interface and English material processing. A desktop widget, global shortcut, and menu bar open a compact conversational assistant panel. Selected folders form a local searchable library. Optional MCP connections let the assistant retrieve explicitly approved context from a configured service.

- [Canonical product specification](docs/specyfikacja-produktowa.md) (Polish)
- [Design system](docs/design-system.md)
- [Delivery Project](https://github.com/orgs/t13foundation/projects/10)
- [Prototype work packages](https://github.com/t13foundation/apple-deskmate/issues)

## Current state

Work package WBS-PROT-01 (Issue #2) delivers a native SwiftUI chat window backed by Apple’s on-device model through Foundation Models. It has a streaming answer, Stop (Escape or ⌘.) that keeps the partial answer, Retry, follow-ups that share one model session, New chat that clears the model context, Markdown answers with Copy returning the raw Markdown, starter prompts that only fill the composer (Return sends, Shift+Return adds a newline), and a model-readiness banner. Recoverable states cover empty input, an unavailable model, guardrail refusals (Edit question restores the text), other errors, and the context limit (the full draft is preserved). There is no cloud fallback and no mock inference.

Verified on the target Mac (Apple M5, macOS 26.6.1, Apple Intelligence on, English) with the signed, sandboxed `dist/DeskMate.app`:

- `--diagnose-model` exits 0: model available, English supported, context size 4096, exact token counting.
- A real on-device answer and follow-up in the app window, with visibly streamed output, Stop and Retry.
- Light and dark mode at normal, compact-tiled and large window sizes were inspected.
- 38 focused tests pass.

Known limitations:

- Checking a very long draft against the context limit can take several seconds before the message appears.
- The model does not always follow length instructions exactly.
- VoiceOver spoken output and the final accessibility pass belong to the later quality package.
- Not implemented yet in this checkout: MCP, persistence and history, widget, compact panel, global shortcut, menu bar. See the Issues.

### My files (Issue #3, WBS-PROT-02)

The sidebar has a My files section. You add a folder or individual TXT, Markdown and PDF files through the system open panel; only what you pick is readable. The app keeps a security-scoped bookmark per source and never scans the disk. Files are chunked and indexed on the Mac with a local BM25 index (no embeddings, no network). In normal chat the model calls one read-only local search tool and answers with inspectable citations: each `[S#]` points to an excerpt that was actually given to the model, opens a source drawer with the file, page and passage, and unknown IDs are stripped and flagged instead of shown as sources. You can also attach up to 5 files to one question, or compare exactly two documents in a staged comparison (a document that would need more than 6 reading steps is refused, never cut).

Limits: 200 files per library, 10 MB and 50 pages per file, 5 attachments per question. Skipped files (unsupported type, scanned PDF without text, oversize, unreadable) are listed with a reason and an action. Refresh finds added, changed and removed files. A source that was moved, deleted or whose access was revoked is treated as revoked: it is not searchable and its excerpts are not returned. Scanned PDFs are not read because OCR is out of scope.

Implemented and unit-tested with synthetic data; real on-device answers were produced headlessly with `--ask` (see below). The SwiftUI screens for My files, the citation drawer and the attachment strip compile but still need verification in the running app by the host: light and dark mode, keyboard, VoiceOver and reduced motion are not yet inspected.

Known limitations of this package:

- The on-device model sometimes skips the search tool and says it found nothing, sometimes ignores that two versions of a document disagree, and sometimes cites an unrelated excerpt when it answers “not in your files”. Citations prove which excerpts the model saw, not that every sentence is supported by them.
- Retrieval is keyword-based (BM25 with light stemming), so questions that share no words with the passage can miss it.
- Image-only PDFs, OCR, DOCX and web pages are not supported. The chosen sources (with bookmarks) and a rebuildable text index are saved as JSON in the app’s Application Support folder, so extracted document text is stored on this Mac until you remove the source. Conversation history is a separate package.

## Build, test and run

Requires macOS 26 and Swift 6.2 or later. The commands below were run on the target Mac with Xcode 27.0 selected per command through `DEVELOPER_DIR`; `xcode-select` still points to Command Line Tools and is not changed. `scripts/test.sh` also passes with Command Line Tools. The deployment target stays macOS 26, and the code must compile warning-free against both SDKs without macOS 27 APIs.

```sh
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer   # omit to use the selected toolchain
swift build -c release            # compile
bash scripts/test.sh              # focused tests
bash scripts/build-app.sh         # assemble and ad-hoc sign dist/DeskMate.app (sandboxed)
open dist/DeskMate.app
dist/DeskMate.app/Contents/MacOS/DeskMate --diagnose-model   # print model readiness and exit (0 ready, 3 not ready)
dist/DeskMate.app/Contents/MacOS/DeskMate --ask "What is a budget?"   # one real on-device generation; refuses if the model is not ready
```

To sign with a free Personal Team identity instead of ad-hoc:

```sh
bash scripts/build-app.sh --sign "<Apple Development identity>"
```

For development, `swift run DeskMate`, `swift run DeskMate --diagnose-model` and `swift run DeskMate --ask "…"` run the same entry points without assembling the app bundle.

Headless file questions use the real on-device model with an in-memory library (nothing is saved, no bookmarks are created). They print to your terminal because you asked for it, and never print document text other than cited excerpts when `--show-excerpts` is given:

```sh
swift run DeskMate --ask "Who approved the budget?" --library Fixtures/Library --show-searches
swift run DeskMate --ask "What is the retention period?" --attach Fixtures/Library/lumen-security-review.pdf
swift run DeskMate --compare Fixtures/Library/lumen-plan-v1.md Fixtures/Library/lumen-plan-v2.md
swift run DeskMate --ask "…" --library Fixtures/Library --follow-up "…" --show-excerpts
```

`Fixtures/Library` is a synthetic “Project Lumen” set (TXT, Markdown, text and scanned PDFs, a Latin-1 file, and a line that tries to inject instructions). `Fixtures/make-library-pdfs.swift` regenerates the PDFs.

`scripts/test.sh` exists because with only Command Line Tools selected, plain `swift test` cannot find the Testing framework: it either fails to compile (`no such module 'Testing'`) or builds and runs zero tests. The script reads the developer directory from `$DEVELOPER_DIR` (else `xcode-select -p`), adds the framework path only for Command Line Tools, fails if no tests ran, and is plain `swift test` under full Xcode.

The app bundle is signed with `App/Resources/DeskMate.entitlements` (App Sandbox only for now). The widget’s App Group is not proved yet and is handled in the widget package.

Apple Intelligence must be enabled, and it was unavailable on this Mac while the primary language was Polish; it worked after English became the primary language. The app shows the unavailable state honestly and opens the relevant System Settings pane on request, but never changes these settings.

The app writes no logs. `--diagnose-model` prints readiness only; `--ask` prints the answer to your terminal because you asked for it.

## Intended runtime

macOS 26 or later, an Apple Intelligence-compatible Mac, and an available on-device SystemLanguageModel. Swift, SwiftUI, Foundation Models, WidgetKit, App Intents, and the official MCP Swift SDK. No paid model API or macOS 27 upgrade is required for the initial scope.

Turn on Apple Intelligence in System Settings before asking a question; the app opens that pane on request but never changes the setting. Apple Intelligence availability and English support are checked at runtime. Xcode 27.0 is used with the macOS 26 deployment target; the widget extension still needs App Group and signing proof on the target Mac in the widget work package. Possession of a Developer Program membership is not assumed.

Use synthetic English samples for demonstrations. MCP can transmit data outside the Mac; connecting a server is a separate trust decision.

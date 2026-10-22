# DeskMate app icon kit

The selected single document/conversation silhouette. Its front is ivory, its folded reverse is lilac, and the exposed shadow on the white face is neutral gray. Do not recolor the shadow lilac or make both sides ivory.

## Canonical artwork

`AppIcon.icon` is the editable Icon Composer package. Its `Assets/` directory contains the canonical SVG layers on identical 1024 × 1024 canvases. They have no outer mask, baked blur or specular highlights. Background and dynamic effects are owned by Icon Composer / the system. `artwork.svg` is a flat reference, not a second editable source of truth.

## Integration

- Xcode: add `AppIcon.icon` to the application target and set the app icon name (`ASSETCATALOG_COMPILER_APPICON_NAME`) to `AppIcon`. Use the layered package, not a screenshot or masked preview, as the production source.
- `compiled/macOS/` contains Apple's actual `actool` output (`Assets.car`, `AppIcon.icns`, and the generated partial `info.plist`). When packaging without Xcode, merge the icon metadata into the existing app Info.plist and copy both resource files. Do not replace the app's other asset catalog or metadata blindly; compile together with any existing catalogs instead.
- `fallback/AppIcon.icns` is a static, full-resolution compatibility icon with every standard 16–1024 px representation. It can be used by the existing manual Mac bundler. It does not implement dynamic clear/tinted appearances on its own.
- `previews/` contains six **masked marketing/review renders** exported by Icon Composer: Default, Dark, Clear Light/Dark, Tinted Light/Dark. These already contain the system mask and effects. Do not use them as unmasked App Store or asset-catalog inputs.
- `qa/visual-matrix.png` shows the exported appearances on light/dark backgrounds at 128, 64, 32 and 16 px.

The app chat owns build integration, actual Finder/Dock/Home Screen checks, signing, Git and product documentation. This kit changes no application behavior, build scripts or existing app icon. Keep the previous integrated resources available until the app-level check passes.

See `qa/verification.md` for evidence and limits; `SHA256SUMS` identifies this exact delivery. No account, device or system settings were changed for these tests.

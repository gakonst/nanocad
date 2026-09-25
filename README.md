# NanoCAD

**Give your idea shape.** A native iPhone and iPad CAD workspace powered by Nanocodex and Astra.

Describe a part, inspect its real STEP geometry, tap the exact faces or edges you want to change, and sketch directly over the viewport. NanoCAD turns those selections and marks into context for your next prompt.

<p align="center">
  <img src="docs/images/workspace.png" width="260" alt="NanoCAD native CAD workspace" />
  <img src="docs/images/selection.png" width="260" alt="Selected CAD face with an exact reference in the composer" />
  <img src="docs/images/markup.png" width="260" alt="PencilKit markup over the CAD model" />
</p>

## What’s here

- SwiftUI with iOS 26 Liquid Glass controls and a compact, growing Nanocodex composer.
- A native SceneKit viewport: orbit, pan, zoom, fit, face picking, edge picking, and vertex picking. No WebView.
- A topology inspector with exact face areas, edge lengths, and vertex coordinates in millimeters.
- PencilKit pen, eraser, colors, undo, redo, and clear. Markup preserves its document revision and captured view across app launches and layout changes.
- Astra generation through Nanocodex’s public managed HTTP API, streamed progress, explicit cancellation, persisted admission identifiers, and resumable event cursors.
- Real STEP imports and exports. A pinned CAD kernel produces native mesh previews with the same geometry references used by [earthtojake/text-to-cad](https://github.com/earthtojake/text-to-cad).
- A real, offline sample bracket, including its STEP, mesh preview, and reproducible source.

## Run on a simulator

Requires macOS, Xcode 26+, an iOS 26+ simulator, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open NanoCAD.xcodeproj
```

Select the **NanoCAD** scheme and an iPhone or iPad simulator, then Run. The sample, topology selection, markup, and preview imports work offline. Run the scheme’s test action for native geometry, streaming, persistence, and UI behavior tests.

For a physical device, set your development team and enable code signing in Xcode. No signing credentials are included.

## Create with Astra

Tap **Astra → Connect with Nanocodex**. NanoCAD embeds the existing Nanocodex Connect dialog in a native sheet. Approve ChatGPT/Astra, an isolated Cloudflare CAD sandbox, and the two CAD file tools for NanoCAD’s conversation. Existing text-only approvals show **Enable CAD creation**. The scoped connection stays in this device’s Keychain. Keep NanoCAD open during generation so its tools can exchange the selected STEP, markup, and generated files. An account key remains available under Advanced connection.

Write a prompt such as:

> Create a 60 × 40 × 5 mm mounting plate with four 4 mm holes, each 6 mm from its adjacent edges.

Or select one or more faces or edges and ask:

> Round these edges with a 2 mm radius.

Connect reuses its approved conversation, explicitly configured with `gpt-6-astra`; each generation has independent, persisted request and transfer identifiers. NanoCAD supplies the current STEP, exact revision and selected references, the bundled exporter, and an annotated image when present. Astra uses a Cloudflare sandbox with Python 3.12 and `cadgen==0.6.6` to produce real STEP and `.cad.json` artifacts. NanoCAD verifies the preview’s SHA-256 revision against the downloaded STEP before replacing the current model. Python and the CAD kernel run in the agent’s execution environment; rendering and interaction run natively on iOS.

If the connection is interrupted, open **Conversation → Resume generation**. Resume preserves the original request and turn identifiers. Stop explicitly cancels the server turn; closing the app merely stops observing it. If Astra finishes without delivering both model files, **Retry generation** starts a new turn with your original prompt and geometry.

## Import existing CAD

Use **+** or **Design menu → Open STEP or preview**. STEP/STP imports use Astra to tessellate the original geometry without remodeling it. Current session setup limits restrict an imported STEP to 600 KB; the total setup payload, including markup and exporter, must fit Nanocodex’s 1 MB configuration limit.

For larger models or offline viewing, export a preview on a computer:

```sh
python3.12 -m venv .cadgen-venv
.cadgen-venv/bin/pip install -r Tools/requirements.txt
.cadgen-venv/bin/python Tools/export_step.py part.step --out part.cad.json
```

Open `part.cad.json` in NanoCAD through Files. A preview imported by itself supports viewing, selection, and markup; editing requires its source STEP. Use **Export STEP** to share a source STEP when one is present.

## Scope and current limits

This is an initial native application, not the full desktop CAD Viewer. It supports leaf bodies and face/edge/vertex references, but not kinematic animation, engineering drawing PDFs, material editing, constraints, or on-device B-rep editing. Markup is a review of a captured camera view, not a constrained CAD sketch. Reference IDs belong to one saved STEP revision and are cleared after regeneration.

Connect uses its own granted conversation and signed native CAD tools; it does not require managed `/files` or `/artifacts` access. No separate login server or callback service is deployed. One active generation is supported per workspace. Live Astra execution requires approving Connect; see [validation](docs/validation.md) for exactly what was exercised.

SceneKit provides a native renderer with Metal backing. Apple now [marks SceneKit deprecated](https://developer.apple.com/documentation/scenekit/); a future renderer can consume the same CAD document contract without changing generation or topology identity.

## Architecture and provenance

- [CAD exporter, references, geometry checks, and limits](docs/exporter.md)
- [Nanocodex API and authentication contract](docs/nanocodex-integration.md)
- [Validation and simulator evidence](docs/validation.md)
- [Third-party notices](NOTICE.md)

Inspired by and built against [earthtojake/text-to-cad](https://github.com/earthtojake/text-to-cad). Its geometry kernel and reference semantics power the CAD export pipeline. Only the composer editor is reused from Nanocodex; the rest of the mobile interface and native viewport are implemented for NanoCAD.

MIT licensed.

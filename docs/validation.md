# Validation

Validated with Xcode 26.6 (17F113), Swift 6, and iOS Simulator 26.5. Synthetic transport tests are separated from live account evidence.

## Native app

The current full iPhone 17 Pro simulator run passed **80 native tests and all eight UI scenarios** in one run. A further 15 targeted generation/HTTP tests passed after tightening legacy-result recovery and terminal missing-output handling.

Coverage includes:

- Real SceneKit face hits and exact reference chips; body, face, edge and point selection; native composer editing and expansion; actual PencilKit drawing and restoration after relaunch.
- Existing Connect dialog opening/cancellation and Keychain-backed project startup.
- Independent project roots, stable conversation identities, switching between models, and unsent drafts surviving app termination.
- Upload completion before admission, exact retry bytes/IDs after an uncertain response, completed artifact downloads without a native file host, revision/hash validation, and explicit server cancellation.
- Observer cancellation on backgrounding without cancelling the cloud turn, reconnecting after the cancellation race, persisted transcript recovery and cursor replay, message coalescing and credential/binary redaction.

An earlier run exposed unsigned-simulator Keychain access and two transcript/status regressions. Simulator ad-hoc signing and the affected behavior were corrected before the complete passing run. No failed or interrupted run is counted as a pass.

The device Release build also passes and is signed for a physical iPhone. See the live boundary below before interpreting a build as proof of cloud execution.

## CAD geometry and Connect bundle

Six Python checks pass on both macOS and a real Linux Cloudflare sandbox against cadgen/Open CASCADE: canonical references, placements, area/length/vertex metrics, normals, winding, positive volume, degenerate sphere edges, and both generated and bundled preview geometry. Same-runtime repeated export remains exact; mesh ordering is not assumed identical between platforms.

All three public Connect SDK contract tests and bundle builds pass on macOS and Linux. Generated JavaScript and license notices match exactly across both environments.

## Server contract

Nanocodex’s durable-file change passes 22 managed Workers tests and 80 Connect tests (one existing Connect test is skipped). The managed journey admits a real Durable Object turn, reads the durable uploaded bytes through actual Just Bash, publishes scoped output, archives the turn, and verifies allowed replay/downloads and cross-grant denial. Its model response is synthetic; this establishes server behavior, not CAD-kernel quality or a live Astra run. Both service typechecks and Worker dry-runs pass.

## Live boundary

A real physical iPhone Connect transfer completed on 2026-09-25: Astra reconstructed a unique 78,973-byte input from three native-served chunks and verified the exact native digest. That earlier foreground transfer also exposed the close-app failure, which motivated the durable upload/publication path.

Separately, the unchanged exporter ran in a real Cloudflare sandbox with Python 3.12.11, cadgen 0.6.6 and build123d 0.11.1. A saved 40 × 30 × 8 mm plate with a centered Ø6 mm through-hole reopened as a valid solid, with matching STEP/preview hashes and measured volume 9,373.805328941526 mm³. That sandbox used root-account authority, not the native Connect grant.

A physical-device run that closes NanoCAD after the new durable submission and reopens its finished CAD result is still being established. Do not infer that result from the tests above. Remote completion notifications, TestFlight distribution, hardware Apple Pencil behavior and large-assembly performance are not established.

Earlier renderer evidence remains available: [iPhone workspace](images/workspace.png), [face selection](images/selection.png), [markup](images/markup.png), [iPad workspace](images/ipad.png), and the separate [Astra geometry workflow](astra-workflow.md).

## Reproduce

```sh
xcodegen generate
xcodebuild -project NanoCAD.xcodeproj -scheme NanoCAD \
  -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR' \
  -parallel-testing-enabled NO -resultBundlePath TestResults.xcresult test
.cadgen-venv/bin/python Tools/test_export_step.py
cd Connect && npm ci --ignore-scripts && npm test && npm run build
```

# Validation

Validated with Xcode 26.6 (17F113), Swift 6, and iOS Simulator 26.5. Synthetic transport tests are separated from live account evidence.

## Native app

The live-preview implementation passed **84 native tests and all eight UI scenarios** in one iPhone simulator run. The subsequent CAD specialist and integrity review passed **90 native tests**. A further run of **all eight iPhone UI scenarios passed** after the drawer and preview review-state corrections. The same project/draft/thumbnail scenario also passed on an iPad simulator.

Coverage includes:

- Real SceneKit face hits and exact reference chips; body, face, edge and point selection; native composer editing and expansion; actual PencilKit drawing and restoration after relaunch.
- Existing Connect dialog opening/cancellation and Keychain-backed project startup.
- Independent project roots, stable conversation identities, switching between models, and unsent drafts surviving app termination.
- Upload completion before admission, exact retry bytes/IDs after an uncertain response, completed artifact downloads without a native file host, revision/hash validation, and explicit server cancellation.
- Observer cancellation on backgrounding without cancelling the cloud turn, reconnecting after the cancellation race, persisted transcript recovery and cursor replay, message coalescing and credential/binary redaction.

An earlier run exposed unsigned-simulator Keychain access and two transcript/status regressions. Simulator ad-hoc signing and the affected behavior were corrected before the complete passing run. No failed or interrupted run is counted as a pass.

Release 0.4.0 builds 6 and 7 were built and installed on the paired physical iPhone. Build 7 moves the pinned skill installation to local sandbox disk after the live check exposed costly small-file writes on shared storage. The public CI run for commit 828ba29 passed all jobs. See the live boundary below before interpreting a build as proof of cloud execution.

## CAD geometry and Connect bundle

Seven Python geometry checks pass on macOS (the original six also passed in a real Linux Cloudflare sandbox) against cadgen/Open CASCADE: canonical references, placements, area/length/vertex metrics, normals, winding, positive volume, degenerate sphere edges, and both generated and bundled preview geometry. Same-runtime repeated export remains exact; mesh ordering is not assumed identical between platforms.

Three skill-installer checks cover the exact pinned bundle, idempotent installation, unsafe paths/symlinks and rejected revisions.

All three public Connect SDK contract tests and bundle builds pass on macOS and Linux. Generated JavaScript and license notices match exactly across both environments.

## Server contract

The durable-file and live-checkpoint server changes pass 48 focused managed Workers tests and 81 Connect tests (one existing Connect test is skipped). The managed journey admits a real Durable Object turn, reads the durable uploaded bytes through actual Just Bash, publishes scoped output, archives the turn, and verifies allowed replay/downloads and cross-grant denial. Its model response is synthetic; this establishes server behavior, not CAD-kernel quality or a live Astra run. Both service typechecks and Worker dry-runs pass.

## Live boundary

A real physical iPhone Connect transfer completed on 2026-09-25: Astra reconstructed a unique 78,973-byte input from three native-served chunks and verified the exact native digest. That earlier foreground transfer also exposed the close-app failure, which motivated the durable upload/publication path.

Separately, the unchanged exporter ran in a real Cloudflare sandbox with Python 3.12.11, cadgen 0.6.6 and build123d 0.11.1. A saved 40 × 30 × 8 mm plate with a centered Ø6 mm through-hole reopened as a valid solid, with matching STEP/preview hashes and measured volume 9,373.805328941526 mm³. That sandbox used root-account authority, not the native Connect grant.

Two real physical iPhone edits completed through the project’s scoped Cloudflare sandbox: a Ø24 upright opening became a 24 × 24 square, then both Ø10 base holes became 10 × 10 squares. The latter saved a valid 63,664-byte STEP with 20 faces; the downloaded native preview matched SHA-256 `0cc07c32843515cefd5c1919c053f0256e50a3d6c563077e71d3e0c4c3c81100`. These prove cloud generation and final delivery, before the specialist/preview update.

A first unchanged re-export was admitted on the physical phone and NanoCAD was terminated, but the app reopened before the server finished; it later delivered a matching STEP/preview pair on a subsequent unlocked launch. A stale process-session error in that run required a deployed server recovery fix.

On 2026-09-25, the signed **0.4.0 build 7** launched a fresh unchanged re-export against the persisted Connect/Astra project agent. The phone saved an admitted `running` turn, and NanoCAD was terminated at 05:21:03 UTC. The same server turn completed while the app remained terminated (verified independently in the retained session by 05:25:47 UTC). NanoCAD reopened at 05:25:59 UTC, resumed that turn, downloaded and committed its final files, removed its pending generation, and retained the final answer plus “Model ready” in its transcript. The new native document's STEP and preview SHA-256 hashes matched the pre-run pair exactly; the STEP is 63,664 bytes, and the preview binds its revision to the exact STEP hash with 20 faces. This verifies completed-while-terminated delivery for an **unchanged re-export**, not a post-update geometry-changing edit or visual proof of an intermediate checkpoint while the phone was closed. One live run does not establish reliability or a latency improvement.

Remote completion notifications, TestFlight distribution, hardware Apple Pencil behavior and large-assembly performance are not established. A push notification needs a separate opt-in APNs-enabled app and durable server publisher; an on-open model receipt is independent of push delivery.

Earlier renderer evidence remains available: [iPhone workspace](images/workspace.png), [face selection](images/selection.png), [markup](images/markup.png), [iPad workspace](images/ipad.png), the [project drawer with a real model thumbnail](images/projects-drawer.png), and the separate [Astra geometry workflow](astra-workflow.md).

The separate [post-change specialist validation](post-change-validation.md) records measured CAD stage times, saved geometry checks and the native rendering review.

## Reproduce

```sh
xcodegen generate
xcodebuild -project NanoCAD.xcodeproj -scheme NanoCAD \
  -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR' \
  -parallel-testing-enabled NO -resultBundlePath TestResults.xcresult test
.cadgen-venv/bin/python Tools/test_export_step.py
cd Connect && npm ci --ignore-scripts && npm test && npm run build
```

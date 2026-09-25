# Validation

Validated on 2026-09-24 using Xcode 26.6 (17F113), Swift 6, and iOS Simulator 26.5. No skipped test cases were used to turn a failure into a pass.

## iPhone 17 Pro

**51 distinct Swift tests pass:** 45 native unit/contract/state tests and 6 UI tests.

The first simulator suite ran the original 22 native tests plus all six UI tests. Five UI tests passed; the caret test incorrectly assumed that double-tapping `8 mm` selected only its digit. iOS selects that measurement together. The fixture was corrected to a plain word and rerun successfully, alongside all 23 new HTTP contract tests. No product change was needed for that test correction. The retained summaries show the original failure and the successful targeted follow-up:

- [Initial suite summary](../evidence/iphone-suite-initial.json)
- [HTTP contract tests and corrected caret test](../evidence/iphone-contract-and-caret.json)

UI checks exercise actual SceneKit face taps, exact reference chips, body/face/edge/vertex inspector selection, native text replacement and caret preservation, long-editor expansion, secure connection fields, a real PencilKit stroke, and drawing restoration after termination and relaunch. Screenshots are actual simulator captures, not mockups.

[Workspace](images/workspace.png) · [Face selection](images/selection.png) · [Markup](images/markup.png) · [Restored markup](images/markup-restored.png)

Native tests include the shipped preview’s digest against its real STEP, invalid mesh buffers, stale-revision invalidation, interrupted/mismatched imports, split Unicode SSE frames, real request/receipt shapes, binary input seeding, artifact hashes, HTTP/auth failures, stable request identifiers after ambiguous admission, cursor recovery without resubmission, and Stop racing workspace creation. HTTP and state tests use isolated synthetic transports; they do not contact a live account.

## iPad Pro 13-inch (M5)

All three additional simulator UI scenarios pass on iPadOS 26.5: native face picking and reference chips, long composer expansion, and a real PencilKit stroke restored after relaunch. The geometry viewport fills the canvas while the composer retains a comfortable centered width. [Result summary](../evidence/ipad-smoke.json) · [Actual iPad screenshot](images/ipad.png).

## CAD exporter and Astra tools

The Python exporter passes **five integration tests** against actual cadgen/Open CASCADE geometry, including repeated assembly placements, normals/winding, degenerate sphere-pole edges, canonical references, exact metrics, and reproducible preview output. See [export validation](../evidence/export-validation.json).

Astra also completed a [real generation and one-hole refinement smoke test](astra-workflow.md). Every saved STEP geometry check passes, and the rendered mesh comparison was reviewed.

## Reproduce

```sh
xcodegen generate
xcodebuild -project NanoCAD.xcodeproj -scheme NanoCAD \
  -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR' \
  -parallel-testing-enabled NO -resultBundlePath TestResults.xcresult test
.cadgen-venv/bin/python Tools/test_export_step.py
```

## Connect and physical iPhone update — 2026-09-25

The public Connect SDK is bundled and its existing hosted SMS approval dialog runs inside the native WebKit sheet. The native app was signed, installed, and launched on an iPhone 17 Pro running iOS 26.6.1. A user-approved Connect conversation completed real Astra text generation.

The updated simulator checks passed **53 distinct native tests and all seven UI scenarios** across the full run and a targeted follow-up. The new cases cover WebKit dialog loading/cancellation, scoped HTTP requests, transfer integrity and runtime identity, reuse of an immutable Astra model selection, and terminal runs that provide no CAD output. The full run passed 52 native tests and six UI cases; the topology case failed to resolve a visible row through accessibility. Its unchanged targeted rerun passed every body/face/edge/point selection and Clear assertion, together with the new runtime identity test. An earlier simulator install stall was interrupted before tests ran; neither failure was counted as a pass.

A real physical iPhone transfer run completed at **2026-09-25 00:44:36 UTC**: Astra read a unique 78,973-byte input in chunks at offsets 0, 32,768 and 65,536, reconstructed it with real tools, and reported the exact native SHA-256. Native served-chunk receipts independently covered every byte. The final persisted validation state was `passed`, with no failures or stream reconnects. This proved input transfer through the approved Connect tools, not CAD output delivery.

Separately, the unchanged exporter ran with cadgen 0.6.6/build123d 0.11.1 in a real Cloudflare sandbox using Python 3.12.11. The saved STEP reopened as one valid solid: a 40 × 30 × 8 mm plate with a centered Ø6 mm through-hole, volume 9,373.805328941526 mm³. Its matching native preview contained seven faces, fifteen edges, ten vertices and 352 triangles. This sandbox used the root account; it does not establish execution through a Connect grant.

The opt-in device launch flags `--validate-connect-transfer` and `--validate-connect-cad` use the grant already in device Keychain. They isolate their files in `Documents/NanoCAD/Validation/<runUUID>/`, preserve the user's document, and save safe reports to `Validation/latest-report.json`. The CAD run requires the newly approved sandbox permission and verifies delivered STEP identity, preview decoding, exact dimensions and both hole boundaries before showing its native viewport.

## Still to establish

A live approved Connect → Cloudflare kernel → native STEP/preview delivery run is pending deployment of explicit sandbox permission and its approval in NanoCAD. TestFlight distribution, hardware Apple Pencil behavior, and large-assembly performance are not established by these checks. The earlier real Astra CAD smoke tests used a separate tool workflow, as documented above.

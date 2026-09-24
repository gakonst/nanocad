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

## Not established by these tests

A live, authenticated prompt-to-artifact round trip from the iOS app has **not** been run: no user account API key was supplied. The real adapter selects Astra and follows the inspected public API, with its wire behavior verified by transport tests. Device signing, TestFlight distribution, hardware Apple Pencil behavior, and large-assembly performance are not tested. Connect-based native sign-in is not implemented because current grants cannot read the required managed CAD files/artifacts.

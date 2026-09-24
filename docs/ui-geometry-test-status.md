# UI and geometry test status

Updated 2026-09-24. Test author owns `UITests/NanoCADUITests.swift` and `Tests/CADDocumentTests.swift`; this status document was requested by the parent agent.

## Coverage

Six UI tests exercise the shipped workspace:

- SceneKit summary reports 11 rendered sample faces; tapping the projected interior of a visible face creates its reference chip and updates its accessibility selection value. Removing the chip deselects it.
- Bodies, faces, edges, and points selected in the topology inspector appear in the composer; Clear removes all selections.
- A real PencilKit drag creates Markup. The saved stroke and chip survive termination and relaunch; Clear drawing removes the chip.
- Replacing the first word of `small steel plate` with `large`, then inserting `r`, produces `larger steel plate`. This checks native selection and caret preservation across SwiftUI updates.
- An eight-line prompt expands into the full native editor and retains its text when collapsed.
- Connection settings show an empty secure key field and disable Connect for empty or whitespace-only input. No credential or network request is supplied.

Named screenshots are attached with `keepAlways` for initial rendering, selected faces, topology, drawing before and after relaunch, native text editing, expanded text editing, and connection settings. Runtime attachments belong to the parent's XCTest result bundle.

Nine document tests cover the hosted app's `Bundle.main` assets, valid optional normals, malformed packed buffers, nonfinite geometry, unsupported formats, prompt reference formation, review persistence and stale revision rejection, rejected import preservation, and STEP digest mismatch rejection.

The inspected sample has 11 faces, 27 edges, 18 vertices, one body, and 1,040 triangles. Its JSON revision equals the bundled STEP SHA-256: `ee24cee9abcb47ffe997ee9a9429e681140cc418b26504ff7eeeede7b45b1384`.

## Launch and persistence contract

Each test initially launches with `--uitesting-reset`. The parent added a DEBUG hook that removes only `WorkspacePersistence.root` when that explicit flag is present. The persistence test's second launch omits the reset flag, retaining only English locale arguments. Tests use SHA-256-derived revisions for persisted STEP fixtures and support the current atomic snapshot implementation.

## Validation and remaining execution

Both suites passed Swift 6 type-checking against the iOS simulator SDK. The document tests were type-checked alongside the real Core sources and CADViewport; the only diagnostic was the expected ignored same-module `@testable import` warning from that standalone invocation.

The test author has not run tests or controlled the simulator. The parent owns runtime execution on simulator `9E567B79-5D7E-496D-B81C-90E102590D8D`.

The parent reported that UI run `test-3` exposed an invalid test assumption: iOS selected `8 mm` as one measurement token, so replacing it yielded `12 plate`. The caret test now uses plain words as described above. That correction requires the parent's rerun. Other runtime outcomes were still pending when this document was written; no runtime pass is claimed here.

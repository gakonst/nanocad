# Working on NanoCAD

Keep CAD rendering and interaction native. SwiftUI owns the workspace, SceneKit owns geometry/camera, and PencilKit owns markup. Main-actor UI state must remain explicit. Render on demand and avoid rebuilding geometry on every selection, token, or keystroke.

STEP is the geometry source of truth. Preview buffers and references must come from the saved STEP via Tools/export_step.py. Match its exact SHA-256 revision before displaying generated artifacts together or sending topology context. Never invent meshes, topology references, generation progress, or successful artifact receipts.

Use Nanocodex's public API contracts and explicitly select Astra. Keep credentials in Keychain; never include them in source, fixtures, logs, screenshots, or UserDefaults. Persist request identifiers before admission and resume the existing turn after uncertain results. Stop must cancel durable server work explicitly.

Use native behavior and failure tests for concrete risks: real viewport hits, draft/caret preservation, drawing restoration, corrupt STEP/preview pairing, interrupted generation, cancellation races, and API response contracts. Keep test fixtures distinct from live account integration evidence. Do not claim an authenticated end-to-end run from mocked transport tests.

Run xcodegen after adding source or resource files. Regenerate Resources/export_step.py from Tools/export_step.py when editing the exporter; CI checks they match. Preserve upstream notices and record any explicit import/rendering limits.

# Reliability review — completed

Delegated agent 2, 2026-09-24. Modified only owned application files `Core/GenerationController.swift`, `Core/WorkspacePersistence.swift`, and `Tests/GenerationTests.swift`; added this review and independent test evidence. No commit. No credential retrieval, Keychain access, real account key, or live API calls.

## Fixes

- Workspace writes now stage a complete STEP/preview pair in a unique directory, then atomically commit `workspace.json`. Interrupted saves cannot replace the STEP under a previously committed preview. SHA-256 must match the preview revision before saving, restoring, or exporting STEP. Legacy pairs are validated; preview-only imports expose no STEP. Preview `name` remains unchanged. The shared STEP path is named `model.step`.
- `clear()` durably commits an empty manifest so New design stays empty after relaunch and cannot resurrect legacy files. Parent added `hasSavedWorkspace` manifest-existence property during concurrent work; preserved it.
- `SavedReview.drawingImage: Data? = nil` is the last initializer argument; old JSON with no image still decodes. Review lookup remains revision-scoped.
- Stop persists `stopRequested` before interrupting the observer, joins the prior task, and then cancels through a fresh client. A delayed create/send result cannot start another turn or overwrite Stop. Ambiguous creation reconciliation uses the original creation ID and inputs; the server cancellation-intent API does not require sending the turn. Persisted Stop resumes cancellation after relaunch. Checks after every admission/download await prevent a stopped task from applying a result.
- Admission IDs, payload, response, and decimal cursor survive relaunch. Retry checkpoints must be saved before another remote call. Terminal failures are not resubmitted. Results require a registered workspace callback; missing callback no longer silently discards the result.
- Refinement validates supplied STEP bytes against the displayed document revision. References sent to cadgen use `model.step#...`, matching the cloud input path, while the displayed human name is untouched. Instructions carry the actual input digest even with no selection. Preview-only edits are rejected at the controller boundary as well as the parent's UI guard.
- Artifact lookup now requires the exact `/brain/outputs/model.step` and `/brain/outputs/model.cad.json` paths and requested turn. A ready catalog missing either output is an error, rather than silently fetching unpublished files. Account `/files` fallback is restricted to an explicit failed publication receipt (including oversized outputs). Downloaded STEP hash and preview filename must match before application.
- Unrelated or unscoped terminal events cannot complete this generation. New pending runs record origin; reconnecting to another server cannot accidentally replay them there.

## Parent API notes

`start`, `resume`, `stop`, and `forgetFailedRun` signatures unchanged. Internal `GenerationClient` protocol and injectable initializer allow isolated tests. `PendingGeneration.stopRequested` and `.origin` are optional for backward decoding. `canResume` remains `pending != nil && !busy` so existing failed dismissal UI works. In the activity UI, show "Retry stop" when stopRequested is true; show only the dismissal action rather than Resume for phase `failed` (resume intentionally does nothing for a terminal failed turn). Parent already disabled workspace replacement/import while pending and added preview-only UI handling.

Client-only finding relayed from agent 3: reject literal `.` and `..` in `NanocodexClient.validateTurnID`, matching `js/managed/src/index.ts:2557`; client is owned by parent, tests by agent 3. No client or UI source edited here.

## Wire evidence

Compared against `/gak-9/ci-worker-asap-20260924`:

- `js/managed/README.md:217-232`: `/v1/agents`, stable Idempotency-Key creation/turn admission, durable cloud `/brain` without a native hand. Existing client uses POST `/v1/agents`, POST `/v1/agents/{id}/turns`, GET `/v1/agents/{id}/events?cursor=...`, POST `/v1/agents/{id}/turns/{turn}/cancel`, GET `/v1/agents/{id}/artifacts?turn_id=...`, GET artifact content, and account-authorized GET `/v1/agents/{id}/files?path=...`.
- `docs/MANAGED_AGENT_CONFIGURATION.md:14-40`: `configuration.environment.files` and `setup_commands` are valid seeded-input mechanisms; general STEP data is not an image/video attachment.
- `docs/MANAGED_AGENT_CONFIGURATION.md:213-234`: immutable exact-turn artifact catalogs, 1 MB/file, 10 MB total, publication failure distinct from turn failure, and publication before terminal receipt.
- `js/managed/src/session-operations.ts:89-130`: publication is atomic; exact-turn listing is complete; artifact paths/digest/size are returned. Controller cannot treat a ready-but-missing output as an oversized publication.
- `js/managed/src/index.ts:6331-6353`, `:6685-6705`: cancel reserves a durable pre-admission turn cancellation intent, including when no turn row yet exists. Stop therefore must not submit a new turn to reconcile cancellation.
- `js/managed/src/index.ts:9559`: artifact publication runs before terminal completion is committed.

The cloud instructions seed the real exporter under `/brain/tools`, mount a native hand for Python/cadgen, and publish STEP and exported preview under `/brain/outputs`. No local Python process is assumed to exist in the cloud brain. Live oversized fallback verifies pair consistency but is still mutable workspace data, as documented by the client.

## Validation

`swift test --package-path evidence/reliability-check` passed: **9 tests, 0 failures**, 2026-09-24 14:01:59 UTC. Log: `evidence/reliability-tests.log`. The harness symlinks actual Core and Tests sources; only camera type and unused default credential loader are stubbed for macOS. All clients use synthetic credentials and actor mocks.

Coverage: ambiguous admission replay with identical request/turn IDs and exactly one application; disconnected stream resumes a >2^53 cursor with no resubmit; Stop during delayed creation; restored Stop with no turn admission; ready catalog missing output must not use live files; mismatched revision never applies; invalid save/orphan directory preserves committed pair; legacy mismatch/export rejection plus durable empty workspace; optional review image backward decoding.

The initial simulator build compiled changed core files but failed because parent UI was already using the then-missing `hasSavedWorkspace`; parent subsequently added it and owns final simulator build/UI validation. Regenerate the Xcode project with xcodegen to include new `Tests/GenerationTests.swift` before final suite (the project snapshot at review time preceded that file). A direct standalone simulator XCTest typecheck omitted XCTest's Swift search path and was inconclusive; the proper SwiftPM test runner above compiled and executed the tests successfully.

No real network admission, model execution, or signed-in artifact download is claimed. The absence of a real account key prevents that verification.

Final validation: all nine GenerationTests passed in the iPhone 17 Pro simulator, and all native document validation tests passed. Atomic document pairing, exact-revision checks, interruption recovery and cancellation behavior are exercised with isolated fixture transports. The public API adapter was separately tested by 23 HTTP contract tests. No authenticated account round trip was performed.

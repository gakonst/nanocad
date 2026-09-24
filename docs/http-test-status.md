# HTTP contract tests — in progress

Owner: delegated agent 3. Only source edit: `Tests/NanocodexHTTPTests.swift`; existing SSE tests and Core/App/project stay untouched. No live credentials or requests. No xcodebuild while parent builds.

Upstream verified: `/gak-9/ci-worker-asap-20260924`, commit `806182e2be5fe94e6a8d93d54bc1634425e1ada6`.

Concrete bug reported urgently to agent 2 (parent not listed in agent directory): `NanocodexClient.validateTurnID` permits literal `.` and `..`. The public handler explicitly rejects these at `js/managed/src/index.ts:2557`; cancellation interpolates this value into a URL path, where it can normalize outside the intended turn route. Add rejection in the shared turn validator. Regression planned for send, cancel, and artifact-filter public entrypoints with zero network requests.

Contract evidence:
- `js/nanocodex/managed/Agent.mjs:38-48,125-169`: POST /v1/agents; agent_id receipt; snake_case creation settings.
- `Agent.mjs:303-319,630-665`: artifact list/content, PATCH settings, POST turn cancellation, POST turns with stable idempotency key and id/input payload.
- `js/managed/src/agent-configuration.ts:6-24,48-59`: /brain file paths, 262144-character file content, 50 files, 32 setup commands, 8192-character command limit, 1000000-byte total configuration cap.
- `js/managed/src/index.ts:5584-5643,11142-11161`: turn ID/idempotency validation, turn_id receipt, accepted 202 or replayed 200.
- `js/managed/src/session-operations.ts:89-130`: SHA-256 digest and separate artifact ID, immutable content, list/publication metadata, 1 MB/file.

Planned tests: isolated per-origin URLProtocol queues/captures using a distinctive regex-valid fixture key, create and settings wire/receipts, binary seed chunks and shell-quoted paths, caller retry identity, turn selection JSON, cancellation, artifact list/hash/size verification, local invalid input refusal, HTTP/auth failures, malformed responses, transport errors. Harness will reject unregistered URLs, including attempted redirects, instead of allowing real network fallback.

Validation pending. Project uses explicit generated PBX references; parent must regenerate with XcodeGen after new test file exists (agent does not edit project).

Final validation: all 23 HTTP contract tests passed on the iPhone 17 Pro iOS 26.5 simulator. The dot-segment turn-ID refusal was fixed in NanocodexClient before this run. Transport fixtures made no live requests. See evidence/iphone-contract-and-caret.json.

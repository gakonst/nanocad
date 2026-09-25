# Nanocodex Connect integration

NanoCAD bundles `nanocodex/connect` 0.6.5 and opens the existing `Dialog.popup` inside a native WKWebView sheet. No separate login website, callback service, provider key, or custom authorization protocol is required.

## Project identity and approval

Each project persists its conversation UUID before opening Connect. The returned durable agent, scoped grant, and device-only Keychain entry belong to that project. The original workspace adopts its existing conversation and files in place. New projects receive separate roots, conversations, and credentials; switching projects never moves a grant between them.

The WebKit parent uses Nanocodex’s canonical origin and the existing `/connect-dialog/` popup protocol. The native bridge checks the main frame, origin, attempt, conversation, agent, expiration, and signed tool catalog. The API validates the grant before it is saved. The dialog requests ChatGPT/Astra, final replies, activity/history/traces, and `urn:nanocodex:agent:execution:sandbox` in the ordinary approval. Send preserves the draft while any required connection is completed.

Requests use `https://nanocodex-connect-api.gakonst.workers.dev/v1/grants/{grant}/agents/{agent}/...`, with the exact approved app ID, Origin and bearer. A grant never becomes an account key. It cannot target another agent or access arbitrary account `/files` or `/configuration`. Disconnect revokes its approval before removing local credentials.

## Durable CAD work

`DurableConnectCADClient` uploads each supplied input before turn admission:

```text
PUT /inputs/{generationUUID}/{filename}
{ "data_base64": "…", "sha256": "…" }
→ { "path": "/brain/connect/{grant}/inputs/{generation}/{filename}", "sha256": "…", "size": 123 }
```

The server bounds requests to 1 MB and decoded inputs to 600 KB, validates canonical encoding and the digest, and derives the path from trusted grant identity. It reserves quotas durably. Identical retries restore the accepted bytes and return the same receipt; conflicting replacements fail. All inputs reach durable storage before the app submits its persisted request and turn IDs. Inputs remain ordinary working files visible to the authorized agent, which verifies and copies them before modeling.

Astra mounts `cf_sandbox` with a stable project name and reuses its installed CAD environment. Python dependencies stay under `/opt`; `/brain` holds durable task files. Rendering stays native on iOS. The model saves both final files under:

```text
/brain/connect/{grant}/outputs/{turn}/model.step
/brain/connect/{grant}/outputs/{turn}/model.cad.json
```

The server snapshots only that turn’s scoped output directory. Artifact ownership survives turn archival. NanoCAD lists `GET /artifacts?turn_id={turn}` and downloads `GET /artifacts/{id}/content`, verifying size, SHA-256, document name, and the preview’s STEP revision. Reads for another grant, agent, or account publication are denied. There is no Connect fallback to mutable arbitrary workspace files. Current publication limits are 50 files, 1 MB per file, 10 MB total.

After admission, the phone only observes events; no phone-hosted file channel is needed. Backgrounding cancels the local observer, not cloud execution. Returning reconnects automatically from the saved cursor. Ambiguous admission reuses identical IDs and input; an explicit Stop cancels durable work. Failed requests can be retried as a fresh turn while retaining their prompt and geometry. The old native reverse-tool client is retained only for requests admitted by older builds.

## Progress and transcript

The compact status uses actual assistant commentary or a conservative description of current tool activity. It does not fabricate percentages or expose raw reasoning. The expanded conversation persists user prompts, assistant updates and answers, plus expandable tool calls/results. Streaming items coalesce by item/phase/model-call identity; cursor replay does not duplicate history. Credential fields and encoded file bytes are removed. The app retains up to 4,000 entries and 8 MB of transcript text, with explicit omission notices.

Completion push notifications are not implemented. Existing local notification mechanisms cannot guarantee delivery after termination; reliable delivery needs APNs registration, a push-enabled profile, and a durable server publisher.

## Build

```sh
cd Connect
npm ci --ignore-scripts
npm test
npm run build
cd ..
xcodegen generate
```

CI checks the generated SDK bundle and dependency notices for drift. Simulator builds use ad-hoc signing so Keychain identity works without distribution credentials. Physical builds need your development team. See [validation](validation.md) for actual tested coverage and live-integration limits.

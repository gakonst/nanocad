# Native integration contract

Implemented from Nanocodex checkout `ci-worker-asap-20260924` at `806182e2b`, without modifying it.

- Construct `NanocodexClient(credentials:)`; restore via `try ConnectionCredentials.load()`.
- Show `ConnectionView { credentials in ... }`; the screen validates the account key via read-only GET `/v1/agents`, saves to device-only Keychain, then invokes the closure.
- `createAgent(requestID:inputFiles:instructions:)` selects `gpt-6-astra`, high effort, standard reasoning. Persist the creation request ID before calling. Retrying must use the identical ID and inputs. `NanocodexInputFile.step(at:)` seeds `/brain/input/model.step`; additional exporter files can be supplied with explicit `/brain/...` paths. General STEP uploads are not supported by `/attachments` (image/video only), so this uses the real `configuration.environment.files` setup mechanism. Base64 chunks decode using setup commands. Entire configuration must remain under 1,000,000 bytes; STEP helper caps at 600,000 bytes. Importing a new external STEP should create a fresh session with that input.
- `send(agentID:prompt:references:revision:requestID:turnID:)`: persist stable request/turn IDs before admission; references come from `document.promptReferences(selection)`. On ambiguous admission failure, retry identical identifiers or reconnect—never silently invent a new turn.
- `events(agentID:after:untilTurnID:receive:)`: callback `NanocodexEvent` is Sendable; hop to MainActor before updating UI. Persist delivered cursor strings. `assistant.delta` and `reasoning.summary.delta` carry incremental text, `assistant.message` carries completed message text, `tool.call` / `tool.result` carry toolName, `turn_completed` carries the final message. A `cursor` control event updates the observer cursor only. Resume the same turn from last delivered cursor after network failure; cancelling the observer does not cancel server work. Call `cancel(agentID:turnID:)` explicitly for Stop.
- `artifacts(agentID:turnID:)` returns published file metadata. Download using `download(agentID:artifact:)`, which verifies size and SHA-256. Immutable publication permits 50 files, 1 MB each, 10 MB total; failed publication is reported in `publications`.
- For larger generated files, `downloadFile(agentID:path:expectedDigest:)` uses real account-authorized GET `/v1/agents/{id}/files?path=...`. These are live workspace bytes; require the completed turn and optionally verify digest. Conventional outputs are `/brain/outputs/model.step` and `/brain/outputs/model.cad.json`. `CADDocument.decode` validates the latter. Download returns local temporary URLs owned by caller; remove when no longer needed.

## Why no generic native Connect login

Connect public SDK is `nanocodex/connect` (JavaScript); no native Swift authorization SDK was found. Its `/v1/device/register` flow is specifically restricted to `nanocodex-cli` signed resources and installation access keys (`js/connect-api/src/devicePolicy.mts`). Native requests with an existing grant require grant bearer + `X-Nanocodex-App-ID` + exact HTTPS `Origin`. A web helper at the app’s origin could complete Connect approval and issue a secure one-time native handoff, but this is new application infrastructure, not an existing native endpoint.

More decisively, `js/managed/src/index.ts:2375` rejects Connect grants for `/artifacts`, `/configuration`, `/required-actions`; lines 2353–2370 reject `/files` and `/attachments`. Connect is viable with app-owned CAD tools/storage, not direct managed CAD file downloads. Account API key mode currently satisfies the requested artifact workflow without app secrets. This is a user account credential, not a model/provider credential.

## Evidence paths in upstream

- `js/nanocodex/managed/Agent.mjs`: creation, settings, turns, event watch, artifacts public wire implementation.
- `js/managed/src/agent-configuration.ts`: environment file paths/limits; total configuration cap.
- `js/managed/src/session-operations.ts:89`: immutable output publication; metadata and download route.
- `js/managed/src/file-download.ts`: authenticated live `/brain` file download.
- `apple/InboxCore/Sources/InboxCore/ManagedClient.swift`: native URLSession account bearer and SSE adapter.
- `apple/InboxCore/Sources/InboxCore/Protocol.swift:93`: SSE framing and event types.
- `apple/NanocodexInbox/InboxView.swift:751`: exact mobile composer; `ChatComposerEditor.swift` and `ChatStyle.swift` in `apple/NanocodexUI/Sources/NanocodexUI`.

Upstream is dual licensed MIT OR Apache-2.0 (`README.md:850`, root license files). This new adapter was written against public contracts. If copying substantive upstream Swift source, retain the chosen license notice and copyright attribution; third-party bundled dependencies have their own licenses.

## Exact native composer recipe

Source: `apple/NanocodexInbox/InboxView.swift:751–1061`, expanded editor `:1107–1162`, model row `:3620`; native text view `apple/NanocodexUI/Sources/NanocodexUI/ChatComposerEditor.swift`.

- Outer `VStack(spacing: 0)` in a continuous-looking rounded rectangle, radius 28. Fill light `#FFFFFF` / dark `#303030`; stroke primary at 0.18 focused, 0.10 idle. Shadow black 0.035, radius 8, y 2. Outer horizontal padding 12, top 4, bottom 6 on system background.
- Model/effort row above input: horizontal padding 16; caption medium font; 44-point minimum control height. Selected model + chevron left, effort control toward right. For NanoCAD pin Astra/high initially; extra Auto/provider controls are optional product features.
- Input row `HStack(alignment: .bottom, spacing: 2)`, padding horizontal 4, bottom 4, top 4. Leading `plus` has a 44x44 hit area. Native editor is flexible. Right send glyph is `arrow.up`, 16 semibold, 32x32 circle inside a 44x44 hit area. Circle uses `Color.primary`; glyph uses system background. Disabled opacity 0.22. Busy with empty draft and no attachments shows `stop.fill`; busy with draft retains Send (queued follow-up). Cmd-Return sends. Successful send dismisses keyboard.
- `UITextView` via UIViewRepresentable uses preferred body font, Dynamic Type, clear background, label text, inset top/bottom 8 and left/right 0, text container line-fragment padding 0. Grows to five measured text lines, then native scrolling. Height minimum is one line plus 16. Only assign `view.text` when text actually differs, so streaming updates do not reset selection/caret. Overflow is measured on actual TextKit layout fragments and delivered asynchronously, rather than estimated from SwiftUI proposed width.
- Empty placeholder overlays top-leading at y=8, body/tertiary, no hit testing and hidden from accessibility. On overflow, show 44x44 `arrow.up.left.and.arrow.down.right` top-right. Opens large-detent NavigationStack sheet with full-height UITextView, 16 padding, title “Message”, Collapse left and Send right. Focus editor when sheet opens; collapse restores composer focus. Conversation change dismisses it and clears focus.
- Attachments show horizontal 120x120 previews with 10 spacing, horizontal padding 16; xmark removal is 20px black/0.65 circle inside 44px hit target. If attachments exist, editor sits above controls with minHeight 52 and horizontal padding 12. Add menu has Photos & Videos, Camera, Files, Context; medium/large detents, corner radius 30. CAD selection chips can use the analogous attachment/context area.

## Connect reference example (future web helper)

```ts
import { Client, Dialog, Transport } from "nanocodex/connect";
const client = Client.create({
  appId: "nanocad", appOrigin: "https://YOUR_APP_ORIGIN",
  dialog: Dialog.popup(), transport: Transport.http(),
});
const connection = await client.connection.connect({
  authorization: "hosted", permission: "agent.run",
  conversationId: crypto.randomUUID().toLowerCase(),
  capabilities: {
    cloudAccounts: { chatgpt: true },
    agent: { finalMessages: true, actionSummaries: true,
             conversationHistory: true, rawTraces: true },
  },
});
const agent = await client.agent.create({ connection });
const turn = agent.turn.prompt({ input: "Build a bracket", idempotencyKey: "persist-before-call" });
const turnID = await turn.accepted();
for await (const event of agent.events.watch({ cursor: "0" })) { /* project event */ }
```

The origin must be real exact HTTPS (loopback development is also accepted); app ID syntax is 1–128 `[A-Za-z0-9._:-]` with first character alphanumeric. Generic wallet-hosted Connect uses the browser wallet ceremony. The separate `Principal.host(...)` flow in `examples/better-auth` requires a registered host project and a server-side project secret; it is unsuitable as a client-only native shortcut. `conversationId` is signed and lowercase UUIDv4, and provisioning uses app/user/conversation identity. `agent.create` opens the pre-provisioned agent; it is not arbitrary session creation. Raw traces are needed for full progress/commentary; default Connect visibility filters commentary and reasoning/tool details.

Native HTTP with a valid grant uses `Authorization: Bearer <opaque-grant>`, `X-Nanocodex-App-ID: nanocad`, `Origin: https://YOUR_APP_ORIGIN`, base `https://api.nanocodex.xyz`, and `/v1/grants/{grant}/agents/{agent}/...`. `PATCH .../settings` supports Astra after provisioning. Tool attachment requests `POST .../tool-host/ticket`, then opens `wss://api.nanocodex.xyz/v1/grants/{grant}/agents/{agent}/tool-host?ticket=...`; the public JS tools package owns the registration/call/result protocol and validates the exact signed tool catalog digest. Do not treat grant as an account key; artifact/file routes explicitly reject it.

## Verification

- Swift 6 native core typecheck passed.
- Swift 6 `arm64-apple-ios26.0-simulator` typecheck including ConnectionView passed.
- `evidence/client-contract/check.swift` executed successfully with synthetic credentials and URLProtocol mock. Checks byte-split Unicode, CRLF and multiline SSE, decimal cursor precision, heartbeat/control handling, terminal events, create/send endpoint shapes, bearer header, and durable request keys.
- `Tests/NanocodexClientTests.swift` adds four regression tests for parser and credential-origin validation for the app's XCTest suite.
- No live account was used; model execution and real network admission/download remain unverified until a user connects.

# Nanocodex Connect integration

NanoCAD bundles `nanocodex/connect` 0.6.5 and opens its existing `Dialog.popup` in a native WKWebView sheet, using the public SDK’s popup protocol. There is no separate login website, callback service, app-owned provider key, or custom cryptographic authorization protocol.

## Approval and native bridge

`Connect/` builds the public JavaScript SDK into `Resources/connect.js`. The local main document uses the canonical Nanocodex origin as its WebKit base URL; the dialog loads from `https://nanocodex.gakonst.workers.dev/connect-dialog/`. The popup becomes a child WKWebView with its standard `window.opener` protocol; only the bundled parent owns the native message bridge. The existing dialog handles SMS account sign-in and approval. API traffic uses the deployed `https://nanocodex-connect-api.gakonst.workers.dev` endpoint. The SDK's unused `api.nanocodex.xyz` default is overridden.

`Client.create` uses app ID `com.gakonst.nanocad`, a fresh conversation UUID, hosted authorization, ChatGPT, final replies, action summaries, conversation history, raw traces, and the exact signed tool catalog in `Resources/connect-tool-catalog.json`. SDK session storage is held in memory. After approval, the WebKit message bridge passes only the scoped grant to Swift. Swift checks the main-frame security origin, current attempt and conversation, granted agent, expiration, and exact tool catalog digest; the API validates the grant before it is saved in device-only Keychain. Cancel and dismissal remove the bridge. Main-frame navigation away from the bundled document is rejected.

CAD execution requests the signed `urn:nanocodex:agent:execution:sandbox` resource through the same hosted dialog. The server projects `agent.execution.sandbox` only from approved resources; the native handoff verifies it. Existing approvals without this capability show **Enable CAD creation** and require a fresh Connect approval. It grants an isolated Cloudflare sandbox, with public network access for CAD dependencies. It does not grant access to personal computers or account-authenticated sandbox egress.

The Connect grant never becomes an account API key. Native HTTP requests include its bearer, exact app ID and approved Origin, and use `/v1/grants/{grant}/agents/{agent}/...`. They cannot target another agent. Disconnect revokes the grant before removing its local credentials. The older account key connection remains under Advanced connection.

## CAD files

Connect intentionally disallows account-only workspace `/files`, `/configuration`, and `/artifacts` routes. NanoCAD uses two explicitly approved app tools through the public reverse-tool WebSocket protocol instead:

- `nanocad_read_input`: reads bounded chunks of the current STEP, markup, or bundled exporter only.
- `nanocad_write_output`: receives chunks of `model.step` and `model.cad.json` only.

The authenticated socket is bound to the exact granted agent and signed catalog. The native host accepts only the current persisted generation ID, then pins its first valid runtime session/turn pair across reconnects. Public managed agent/turn IDs and hosted-tool runtime IDs are separate identifiers. File transfer stays on the root agent. Chunks are at most 32 KiB; output files are at most 80 MB. Each file has an exact total size and SHA-256. Identical chunks may be retried; conflicting data, other generations, paths, or agents are rejected. Files persist across connection loss and only replace the visible document after the complete STEP/preview digest pair validates.

The public socket protocol uses a short-lived ticket, catalog/ready handshake, turn metadata, call/result/ack messages, deadlines, byte budgets, heartbeat, and bounded reconnect. Neither tickets nor credentials are logged. Cloud work selects `gpt-6-astra`, high effort; later prompts verify the retained model without patching its immutable selection, using the real cadgen exporter and execution hands. The model transfers file bytes programmatically through Code Mode rather than reproducing geometry or encoding bytes in its reply.

Keep NanoCAD open while creating. The native app temporarily prevents automatic screen locking while a generation is active. iOS may suspend its tool connection when backgrounded. Resume retains the original request/turn IDs and cursor; Stop cancels the server turn explicitly. A terminal turn without both completed outputs becomes a recoverable failure; Retry generation uses a fresh request and turn while preserving the original prompt and input geometry. An interrupted nonterminal turn still resumes its existing IDs. Account-key mode retains immutable server artifacts and account-only file fallback.

## Build

```sh
cd Connect
npm ci --ignore-scripts
npm test
npm run build
cd ..
xcodegen generate
```

The shared catalog's domain-separated SHA-256 is `0xab8780ca9aeab58e676f213b6a1e56a556121029ccafcf2f0cf0848ada68d84e`. The build checks its exact normalization against the public SDK. CI rebuilds the JS bundle and rejects drift.

See [validation](validation.md) for the actual tested boundary. Native WebKit dialog loading and synthetic grant/file tests do not prove a user-approved live Astra round trip.

# Embedded Connect dialog

This bundles the public `nanocodex/connect` SDK for NanoCAD's WKWebView sign-in sheet. It uses the existing Nanocodex dialog and production API. Nothing in this directory is deployed as a website or server.

Run `npm ci --ignore-scripts`, `npm test`, and `npm run build` here. The generated `../Resources/connect.js` is included in the iOS app. Tool definitions are shared with native Swift through `../Resources/connect-tool-catalog.json` and verified against the SDK before bundling.

The native bridge receives one scoped grant for the initiating attempt. Session data remains in memory until handed to the device's Keychain. No account key or provider credential is bundled.

# Notices

NanoCAD is MIT licensed. `App/ChatComposerEditor.swift` is adapted from Nanocodex, copyright © 2026 Nanocodex Contributors, under the MIT license reproduced in `docs/NANOCODEX-LICENSE-MIT.txt`. The user requested reuse of the composer. Other native UI and API adapter code is original to this app.

The CAD pipeline depends on **cadgen 0.6.6**, from [earthtojake/text-to-cad](https://github.com/earthtojake/text-to-cad), copyright © 2026 Thompson Labs LLC, MIT licensed. NanoCAD’s exporter calls the public cadgen scene API and uses the same topology reference scheme. It does not embed the upstream web UI.

CAD kernel dependencies run in the Python execution environment and are not linked into the iOS binary:

- build123d — Apache-2.0.
- OCP Python bindings — Apache-2.0.
- Open CASCADE Technology — LGPL-2.1 with its additional exception.

See [exporter documentation](docs/exporter.md) for upstream license links and the exact tested package versions. Preserve their license terms when redistributing those dependencies.

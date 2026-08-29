# Third-party notices

Pupa ships the following third-party code in its binaries. Each is used under
its own licence, reproduced in that project's repository.

`AGUIKit/` has no external dependencies.

| Package | Licence | Copyright | How it gets here |
|---|---|---|---|
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | MIT | 2020 Guillermo Gonzalez | Direct — renders chat markdown |
| [NetworkImage](https://github.com/gonzalezreal/NetworkImage) | MIT | 2020 Guille Gonzalez | Transitive, via swift-markdown-ui |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | BSD-2-Clause | 2014 John MacFarlane | Transitive, via swift-markdown-ui |
| [WebRTC](https://github.com/stasel/WebRTC) | BSD-3-Clause | The WebRTC project authors | Direct — voice session transport |

All four are permissive and impose no copyleft obligation on Pupa's own
MPL-2.0 files, nor on `AGUIKit/`'s MIT ones. Attribution is the requirement
they do impose, which is what this file satisfies.

Adding or removing a dependency means updating this table. `swift-cmark` and
`NetworkImage` are listed because they are linked into the shipped app, even
though `Package.swift` never names them.

Pupa's own licensing is in [README.md](README.md#license) — MIT for
`AGUIKit/`, MPL-2.0 for everything else.

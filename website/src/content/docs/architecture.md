---
title: Architecture
description: Contributor architecture and implementation references for Photo Export.
---

Photo Export uses SwiftUI and system frameworks. For the current object graph,
module responsibilities and export data flow, read the
[contributor architecture reference](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/reference/architecture-conventions.md).
It is the maintained source for the role map, design rationale and contracts that
bind the export pipeline.

The reference starts with app composition and links to the source owners. Its
later sections cover cancellation, actor isolation, destination identity,
record ownership, final file commits and extending the pipeline.

For related contributor tasks:

- [Build, test and contribute](https://github.com/valtteriluomapareto/photo-export/blob/main/CONTRIBUTING.md)
- [Auto Export behavior](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/reference/auto-export-behavior.md)
- [Export record persistence](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/reference/persistence-store.md)
- [Swift and SwiftUI patterns](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/reference/swift-swiftui-best-practices.md)
- [Documentation guide](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/README.md)

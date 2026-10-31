# Provenance and licence register

Rule: every dependency or reused material is listed here before it ships, with licence and GPLv3-or-later compatibility.

| Component | Source | Licence | Use | GPLv3 compatible | Notes |
|---|---|---|---|---|---|
| Apple system frameworks (ScreenCaptureKit, AVFoundation, VideoToolbox, Metal, AppKit, SwiftUI) | macOS SDK | system libraries | linked dynamically | yes (system library exception) | not redistributed |
| Own code | this repository | GPLv3-or-later | all of `Sources/` | — | written from scratch; no code from other products of the author |

Candidate, not yet added: FFmpeg (LGPL-2.1+, dynamic, no GPL/nonfree flags) for formats VideoToolbox lacks.
Do not add GPL-incompatible components (e.g. GPLv2-only).

# Building SADROG

Requirements: macOS 15+, Xcode 16+ command line tools (Swift 6), Apple Silicon.

```
swift build -c release          # binary
# the automated test suite depends on private media fixtures and is not part of the public source
SADROG_BUILD_DIR=$HOME/sadrog-build scripts/build_app.sh "<codesign identity>"   # SADROG.app, signed
```

`scripts/build_app.sh` writes the app bundle under `SADROG_BUILD_DIR`. Official releases are signed with a Developer ID and notarized by Apple; a build from source can be signed ad hoc (`-`) for your own use.
Activation (trial / permanent) talks to the author's service. Without activation you can open, edit and save projects; a new recording and an export need an active trial or permanent activation (https://gordas.dev/sadrog).

## Tests

`swift test` runs the XCTest suite in `Tests/SadrogCoreTests`. Scratch files go to `SADROG_TEST_ROOT` (default: a folder under the system temporary directory). Tests that need media or projects that are not distributed with the repository (pre-rendered synthetic clips, a private demo project) are skipped automatically; everything else runs on any Apple Silicon Mac with macOS 15+. Some tests encode short synthetic videos and take under a minute in total. No test contacts the production activation service.

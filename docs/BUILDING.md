# Building SADROG

Requirements: macOS 15+, Xcode 16+ command line tools (Swift 6), Apple Silicon.

```
swift build -c release          # binary
# the automated test suite depends on private media fixtures and is not part of the public source
SADROG_BUILD_DIR=$HOME/sadrog-build scripts/build_app.sh "<codesign identity>"   # SADROG.app, signed
```

`scripts/build_app.sh` writes the app bundle under `SADROG_BUILD_DIR`. Official releases are signed with a Developer ID and notarized by Apple; a build from source can be signed ad hoc (`-`) for your own use.
Activation (trial / permanent) talks to the author's service. Without activation you can open, edit and save projects; a new recording and an export need an active trial or permanent activation (https://gordas.dev/sadrog).

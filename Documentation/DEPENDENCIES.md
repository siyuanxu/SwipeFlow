# Native Playback Dependency Policy

This document records the intended dependency and distribution policy. It is a
technical compliance plan, not legal advice. No third-party binary is currently
stored in this repository.

## Development-only runtime

The `NativePlayback` package can discover a local libmpv through `pkg-config`.
On Apple Silicon development machines, `brew install mpv pkgconf` provides a
convenient runtime for compiling and testing the C API adapter. This Homebrew
build is GPL-linked and has absolute Homebrew dependency paths. It must never be
copied into the app bundle, attached to a release, or treated as evidence that
the release profile is compliant.

The current Homebrew bottle also targets the developer machine's newer macOS
SDK, so a minimum-deployment warning is expected when exercising the macOS 14
package locally. The reproducible release build must set and verify macOS 14 as
its deployment target; the Homebrew bottle cannot be used to validate that
requirement.

Core media-source development does not require mpv. Keeping `NativePlayback` as
a separate package ensures `swift build` and `swift test` at the repository root
remain independent of the development-only native runtime.

## Decision

SwipeFlow will use a reproducible, dynamically linked LGPL-only libmpv build.
The build must use fixed upstream release tags and record source hashes, build
options, linked libraries, patches, and license texts.

The app must not ship a package-manager installation copied from a developer
machine. A release build is eligible for bundling only after its complete
dependency graph and corresponding source archive have been produced by the
project's build workflow.

SwipeFlow does not expose or automatically load subtitle tracks. The release
runtime sets `sid=no`, `secondary-sid=no`, `sub-auto=no`, and
`sub-visibility=no`. mpv 0.41.0 still requires libass at build and link time,
so libass and its mandatory text-shaping dependencies remain passive runtime
dependencies. The project builds libass without CoreText or Fontconfig and
without a system font provider.

## Required build profile

The intended mpv profile starts with:

```text
meson setup build \
  -Dgpl=false \
  -Dlibmpv=true \
  -Dcplayer=false \
  -Dbuild-date=false
```

The implemented profile is pinned in `Scripts/NativeRuntime/versions.env` and
built by `Scripts/NativeRuntime/build.sh`. GPL-only mpv files are excluded,
libmpv is built as a shared library, and the CLI player is not part of the
application bundle.

The FFmpeg dependency must be built as shared libraries with GPL and nonfree
features disabled:

```text
--disable-gpl --disable-nonfree --enable-shared --disable-static
```

No external codec library may be enabled until its license is independently
reviewed. In particular, a GPL library cannot be added to an LGPL-only FFmpeg
build merely because the same codec also has a native FFmpeg decoder.

## Application integration

- Use libmpv's Render API rather than native-window embedding.
- Keep the event loop off the main actor and use wakeup callbacks plus
  asynchronous commands for loads and network operations.
- The initial macOS surface uses CGL/OpenGL 3.2 because libmpv's macOS OpenGL
  backend requires CGL. Keep this deprecated Apple API isolated behind
  the playback adapter, create the render context before loading media, and
  keep target-time blocking disabled on the UI draw pass.
- Prefer VideoToolbox hardware decoding with software fallback.
- Pass transient HTTP headers and signed URLs in memory. Never include them in
  logs, crash annotations, analytics, persisted playback history, or diagnostics.
- Clear the loaded resource and request headers whenever a pooled engine is
  unloaded or reused.
- Check `MPV_CLIENT_API_VERSION` and defensively handle option/property changes.
- The local ad-hoc build uses the library-validation entitlement because macOS
  does not treat separately ad-hoc-signed dylibs as sharing the app's signing
  team. The outer app signature still seals the bundled libraries. Remove this
  exception when the app and all dylibs are signed with one Developer ID.

## Release gate

Before any `.dylib` or `.xcframework` is committed or attached to a release, the
release workflow must produce and verify all of the following:

1. Pinned mpv, FFmpeg, and transitive dependency versions and source hashes.
2. Complete configure/Meson output proving the selected license profile.
3. The exact corresponding source archives, local patches, and build scripts.
4. `otool -L` output showing only bundled relative dependencies or Apple system
   frameworks; no Homebrew or developer-machine paths.
5. License and copyright notices for every bundled library.
6. An in-app acknowledgements view and a download-page link to corresponding
   sources.
7. An arm64 ad-hoc signed bundle tested on a clean macOS account.

The local build currently satisfies items 1–5 and produces an audited arm64
ad-hoc bundle. Items 6 and the clean-account portion of item 7 remain release
work; no native binary is committed to the repository.

## Primary references

- [mpv repository and license summary](https://github.com/mpv-player/mpv)
- [mpv detailed copyright and LGPL build notes](https://github.com/mpv-player/mpv/blob/master/Copyright)
- [libmpv client API header](https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h)
- [libmpv embedding examples](https://github.com/mpv-player/mpv-examples/tree/master/libmpv)
- [FFmpeg license and compliance checklist](https://ffmpeg.org/legal.html)
- [FFmpeg detailed license and external-library effects](https://ffmpeg.org/doxygen/trunk/md_LICENSE.html)

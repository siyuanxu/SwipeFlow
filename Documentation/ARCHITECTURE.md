# SwipeFlow Architecture

SwipeFlow is split into modules so the feed and playback code never depends on a
specific server or directory layout.

## Modules

- `SwipeFlowCore` contains media models, the `MediaSource` protocol, source
  registry, and the UI-facing playback engine boundary. It has no connector,
  network, Keychain, or libmpv dependency.
- `SwipeFlowConnectors` contains local video, `.strm` directory, and optional
  Vidpick sources. The Vidpick connector is a separate implementation of the
  same protocol and uses only Vidpick's client API.
- `SwipeFlowApp` is the SwiftUI composition root. It selects a local source,
  resolves opaque media references, coordinates the playback pool, and embeds
  the native video view in the vertical feed.
- The separate `NativePlayback` package contains `SwipeFlowMPV`, which now owns
  client API validation, libmpv lifecycle, serialized commands, event waiting,
  the first `PlaybackEngine` adapter, and a macOS Render API view.

## Media source contract

`MediaSource` has three operations:

1. Browse a cursor-based page of `MediaItem` values.
2. Resolve an opaque item identifier into a short-lived `PlaybackResource`.
3. Perform an optional organization action when the source advertises that
   capability.

Catalog items do not contain playback URLs or HTTP headers. This keeps signed
URLs and authorization material out of ordinary view state and serialized
models. A `PlaybackResource` may contain sensitive runtime data, so it must not
be persisted or logged.

Connectors explicitly advertise capabilities. Local connectors currently
advertise only browse and playback. Destructive actions remain unsupported by
default; a future remote connector must implement confirmation in the UI and
server-side authorization separately.

## Vidpick source rules

- Server configuration accepts credential-free HTTPS URLs only. A password is
  retrieved from macOS Keychain when a request is made and is not stored in the
  connector configuration or user defaults.
- Catalog browsing calls Vidpick's scan endpoint and stores media paths only as
  opaque item identifiers. Signed playback URLs do not enter catalog state.
- Playback resolution requests Vidpick's media endpoint with Basic
  authentication, blocks automatic redirects, validates the returned HTTPS
  location, and gives libmpv a header-free final URL. Vidpick credentials are
  therefore never forwarded to the media storage host.
- The connector currently advertises browse and playback only. Remote state,
  organization, and deletion are outside this milestone.

## Local source rules

- Files are enumerated beneath the user-selected root without following symbolic
  links.
- Item identifiers are relative paths interpreted only by their owning source.
- Resolution checks the item remains beneath the selected root and still has an
  allowed extension.
- `.strm` files are read only when playback is requested, have a 64 KiB limit,
  and accept local files plus HTTP(S) URLs. Other schemes and credentials
  embedded in URLs are rejected.

## Player integration boundary

`SwipeFlowMPV` receives a `PlaybackResource` in memory and never logs the URL or
headers. Its first adapter supports local files and header-free remote URLs,
with load, play, pause, seek, stop, and a headless integration-test mode. Loads
wait for libmpv's `FILE_LOADED` event before exposing the paused state, so feed
controls do not race media initialization. It rejects per-resource HTTP headers
until they can be applied and cleared without leaking across pooled engines.
The feed depends on a pool of `PlaybackEngine` instances rather than calling
libmpv directly.

Each render-capable engine creates its libmpv OpenGL render context before any
media is loaded, as required by libmpv, and retains the CGL context while the
engine is pooled. `MPVVideoView` attaches that context to an AppKit OpenGL 3.2
surface for SwiftUI instead of owning the render context. The update callback
only schedules a display pass; every render call runs with the same locked CGL
context. Target-time blocking is disabled on the UI render pass to avoid
stalling SwiftUI. OpenGL is deprecated by Apple, but libmpv's macOS OpenGL
backend explicitly requires CGL; this boundary is isolated so a future backend
can replace it without changing the feed or source protocols.

The repository root intentionally remains buildable without libmpv. Native
playback is a nested package discovered through `pkg-config`. The main app uses
the project's packaged LGPL-only runtime, embeds its 12 versioned libraries in
`Contents/Frameworks`, and resolves them through `@rpath`; a build audit rejects
Homebrew and developer-machine paths. Homebrew mpv remains development-only.

The intended pool window is one previous item, the current item, and two next
items. Pooling, preloading, and vertical paging belong above the engine adapter
and below the SwiftUI feed UI.

`PlaybackPool` now implements this four-item window. It prioritizes the current
item, then the next two, then the previous item. Engines leaving the window are
unloaded and reused for items entering it. Resolution and loading failures are
stored only as non-sensitive categories; raw errors and `PlaybackResource`
values are not retained.

The native dependency and release gate are documented in
[`DEPENDENCIES.md`](DEPENDENCIES.md).

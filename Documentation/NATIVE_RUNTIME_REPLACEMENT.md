# Native runtime notices and replacement

SwipeFlow embeds libmpv, FFmpeg, libplacebo, libass, FreeType, FriBidi, and
HarfBuzz as dynamically linked libraries. These components remain under their
respective licenses. The accompanying `Licenses` directory contains the
license and copyright notices distributed with the runtime, while
`SOURCE_MANIFEST.sha256` identifies the exact upstream source archives used by
the build.

The source archive URLs, versions, checksums, configuration, packaging, and
audit scripts are available in the public SwipeFlow repository under
`Scripts/NativeRuntime`. Running the following command on an Apple Silicon Mac
with the documented build tools creates a replacement-compatible runtime:

```sh
Scripts/NativeRuntime/build.sh
```

To use a modified compatible runtime, replace the versioned `.dylib` files in
`SwipeFlow.app/Contents/Frameworks` while preserving their filenames and
`@rpath` install names. Then apply a new signature to the modified application.
For local testing, an ad-hoc signature is sufficient:

```sh
codesign --force --deep --sign - --timestamp=none SwipeFlow.app
```

Changing these libraries may affect compatibility and security. SwipeFlow does
not restrict reverse engineering for the purpose of debugging or modifying the
LGPL-covered runtime components.

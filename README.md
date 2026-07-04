# knots playground (GitHub Pages)

This branch is an orphaned `pages` branch containing a static, prebuilt copy
of `examples/playground` (from the `zig16` branch), targeting
`wasm32-freestanding` via [zjb](https://github.com/scottredig/zig-javascript-bridge) —
no Emscripten involved.

It is not meant to be edited directly. To update it, rebuild
`examples/playground` with:

```sh
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

from `examples/playground` on `zig16`, then copy `zig-out/`'s contents here.

Served via GitHub Pages, requires a browser with WebGPU support.

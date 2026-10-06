<p align="center">
  <img src="doc/logo/phosphor-small.webp" alt="phosphor logo" width="256">
</p>

<h1 align="center">phosphor</h1>

<p align="center">A fast terminal UI framework for Zig, with the glow of old CRTs.</p>

---

Phosphor uses an Elm-style architecture (`init`, `update`, `view`) for apps and widgets.
Its renderer, **thermite**, draws pixels with Unicode block characters, renders only what
changed between frames, and supports 24-bit color.

## Build

Requires Zig 0.17.0 (pinned in `mise.toml`).

```sh
zig build            # library + caps-check tool
zig build test       # run tests
zig build examples   # build all examples
```

## Examples

```sh
zig build run-repl-demo     # readline-style REPL widget
zig build run-mandelbrot    # animated Mandelbrot zoom
zig build run-hypercube     # rotating 4D tesseract
zig build run-sprites       # sprite animation
```

Low-level thermite examples (no app framework) are in `examples/thermite/`.

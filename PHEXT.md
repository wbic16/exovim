# PHEXT.md — phext support for this exovim fork

This fork adds **phext scroll navigation** to exovim as a purely additive
runtime/Lua plugin: no C changes, no changes to any existing upstream file.
The patch set is recorded in [PATCHES.md](PATCHES.md); the design this
implements is summarised below (full design: task 33.5.9/7.5.9/5.5.8 design
document, "Neovim + Phext — Design: Phext-Scale Navigation in a Modal
Editor").

## What a phext is

A phext is a plain-text format addressing text in 11 dimensions: 2D text
(lines × columns) inside a *scroll*, and a 9-component coordinate
addressing the scroll:

```
library.shelf.series/collection.volume.book/chapter.section.scroll
```

Components are 1-based, never below 1, and have **no upper bound**
(libphext 0.4.0 removed the old 999 cap). Coordinates are internal to one
phext — the same coordinate in another file is a different scroll. The
address space is sparse: most coordinates are empty space, not scrolls,
and every cost in this plugin is proportional to the *occupied* scrolls,
never to the coordinate space.

Structure is encoded by nine ASCII delimiter bytes in the byte stream
(from libphext-rs `src/phext.rs`, constants `LIBRARY_BREAK`..`SCROLL_BREAK`;
the identical table drives `parse_phext.py`):

| dimension | byte | dimension | byte | dimension | byte |
|---|---|---|---|---|---|
| library | 0x01 | collection | 0x1D | chapter | 0x19 |
| shelf | 0x1F | volume | 0x1C | section | 0x18 |
| series | 0x1E | book | 0x1A | scroll | 0x17 |

(0x1B is *not* a break.) A delimiter increments its dimension and resets
all lower dimensions to 1. Delimiters are ASCII control bytes, so a
conforming phext is valid UTF-8 as a whole byte stream.

## Classification (phext-upgrade A/B/C/D)

| part | class | why |
|---|---|---|
| The `.phext` file format handling (load / index / serialise) | **A — canonical phext** | The file already *is* canonical phext: text, stable coordinate identity per scroll, per-scroll granularity, single-scroll access without scanning, provenance via git/SQ. The plugin adds no conversion, no sidecar, no shadow format; its Lua delimiter walk reads/writes the canonical stream and is cross-checked against an independent Python walker and (as test oracle) libphext semantics. |
| Buffer contents (what the user edits) | **B — derived view** | A scroll buffer is a materialisation of one scroll, rebuilt from the canonical stream on every jump and disposable without loss; changes flow back only through `:write` (`buftype=acwrite`). |
| The sparse index, outline (TOC), quickfix results, title list | **B — derived view** | All are rebuilt-from-canonical structures, invalidated by the session revision counter, never written back as truth. |
| Undo history | **D — leave alone** | Session state with no stable identity or provenance value. exovim's per-buffer undo is used as-is; undo is not persisted into the `.phext`. |
| Treesitter grammar, LSP, SQ sync, xz sealing | **D — leave alone (v1)** | Real projects with their own invariants; none is needed for navigation or byte-identical editing. Named refusals, not omissions. |

## Coordinate map

There is exactly one store: the `.phext` file itself, at its filesystem
path. Inside it, the coordinate map *is* the format's own map — scroll
text lives at its coordinate, nothing is re-encoded. The manifest scroll
convention of the phext ecosystem (a scroll at 1.1.1/1.1.1/1.1.1 naming
the document) is honoured by treating the home coordinate as the default
landing scroll on open.

## The buffer model: scroll-as-buffer

- The file on disk is the only truth. Opening it runs a single-pass
  delimiter walk once, building a sparse index (ordered occupied list +
  coordinate→span map), and displays one scroll in a normal buffer named
  `phext://<path>@<coordinate>`. One buffer per *file*, reused across
  scrolls.
- **No delimiter byte ever enters a buffer.** Buffers are line-oriented
  and cannot hold the control-byte stream faithfully (NUL handling alone
  breaks byte identity), and user-editable delimiters would silently
  merge scrolls — the worst failure an addressed format can have. There
  is deliberately no raw whole-file editing mode.
- "Occupied" = span of ≥ 1 byte between delimiters. Zero-length spans
  are address space. Consequence, stated plainly: **emptying a scroll
  and saving deletes it.** `:PhextDelete` is sugar over clear + save.

## Navigation (what phext-scale navigation means here)

A coordinate gets the ergonomics Vim gives line numbers: direct entry
(`:PhextGoto`, with occupied-only completion), display in the statusline,
marks, and the jumplist. Two kinds of motion, never conflated:

- **Arithmetic motion** steps a dimension (select with `g1`–`g9` /
  `:PhextDim`; step with `g]`/`g[`, `:PhextStep`). Stepping increments
  the dimension and resets every lower dimension to 1 — exactly what the
  delimiter byte does when parsing. Backward steps clamp at 1. Landing
  on empty space is legal: that is how scrolls are created.
- **Populated motion** jumps between occupied scrolls only (`]]`/`[[`,
  `:PhextNext`/`:PhextPrev`), via binary search over the ordered
  occupied list — O(log k), never a scan. `]P`/`[P` do the same within
  the active dimension (nearest occupied scroll in the step direction
  with the prefix above that dimension fixed).

Structural view: `:PhextToc` opens a read-only outline showing one *zoom
arm* at a time — Outer (library.shelf.series), Middle
(collection.volume.book, scoped to the current Outer arm), Inner
(individual scrolls of the current Outer+Middle scope) — populated nodes
only, cached per (revision, arm, scope). Search: in-scroll `/` stays
native and scroll-scoped; `:PhextSearch` searches all scrolls once and
fills the quickfix list (module = coordinate); `:PhextTitles` picks a
scroll by first line via `vim.ui.select`. Full reference:
`runtime/doc/phext.txt`.

## Editing invariants (test-enforced)

1. Delimiter bytes are never user-editable text (see buffer model).
2. An edit touches exactly one scroll; the serialised diff is confined
   to that scroll's span (mutation control in the test suite).
3. Save is a pure function of (original bytes, occupied edits): an
   unmodified `:write` does not touch the file (mtime preserved); the
   serialiser preserves original gap bytes verbatim around untouched
   scrolls and computes canonical gap breaks only where edits force it.
4. If the file changed on disk since load, `:write` refuses
   (E813-style abort) rather than overwriting stale spans.
5. A scroll's trailing newline is content, not formatting: the plugin
   moves text between buffer lines and spans byte-exactly (tested for
   scrolls ending with 0, 1, and 2 newlines, an empty scroll, and a
   scroll that is only `\n`).

## Measured costs (agi.phext: 1,552,681 bytes, 7,294 scrolls)

Measured 2026-11-08 with a stock Neovim 0.11.4 (LuaJIT) driving this
runtime headlessly, on the Muse VM (not the build host of record),
against the original master-based (0.13.0-dev) tree. The runtime code
is byte-identical on this fork's 0.12.6 release base; the functional
battery was re-run in full on the release base — see the verification
receipts in PATCHES.md.

| operation | design budget | measured |
|---|---|---|
| open + sparse index build | ≤ 100 ms | **37.8–45.6 ms** |
| coordinate jump (mean of 200) | ≤ 5 ms | **0.074–0.107 ms** |
| outline outer-arm build (uncached) | ≤ 20 ms | **22.0–25.6 ms — over budget** |
| keystroke path | zero index/outline/serialise work | by construction (edits are per-scroll captures) |

The outline build is the one budget miss: it is ~25 % over on this
hardware. It runs once per (revision, arm, scope) and is cached
thereafter, so the cost is paid on first open and after edits, not per
keystroke or per render — but the number is reported as measured, not
rounded down to the budget. Under a plain Lua 5.1 interpreter (no JIT)
the same index build takes ~220 ms, which is why the perf claim is
stated for Neovim's LuaJIT only.

Round-trip receipts (same date): byte-identical canonical rebuild for
every real corpus file tested (agi.phext, CYOA 4.6 MB / 830 scrolls,
singular.phext, tasks.phext, skills.phext, emise.phext, incipit.phext,
and the rest of `~/workspace/phext/*.phext`); index coordinates and span
lengths match an independent Python delimiter walk exactly on
tasks.phext and agi.phext.

## Building this fork with phcc

This fork's C tree is unmodified upstream, so it builds with
[phcc](https://github.com/wbic16/phcc) (the phext-based TinyCC
modernisation) exactly as upstream does, plus one CMake pre-seed.
First verified 2026-11-08 on aletheia-core against phcc tip
`bdf12df21530be0924dd3c8881d6687dd8ce42bf` and the original
master-based patch base `c868e1ab3d11ac2a0cc3c284b16808f3de5adf31`;
re-verified on this fork's 0.12.6 release base — see the receipts in
PATCHES.md. The recipe is unchanged:

```sh
# deps are built first with the system compiler (see the L2b caveat):
cmake -S cmake.deps -B .deps -G Ninja -DCMAKE_BUILD_TYPE=Release -DUSE_BUNDLED_LUA=ON
cmake --build .deps

CC="<path-to-phcc>/tcc -B<path-to-phcc>" \
cmake -B build-phcc -G Ninja -DCMAKE_BUILD_TYPE=Release -DPREFER_LUA=ON \
      -DLUA_MATH_LIBRARY=/usr/lib/x86_64-linux-gnu/libm.so
cmake --build build-phcc
```

- `PREFER_LUA=ON` selects the bundled Lua 5.1.5 instead of LuaJIT
  (LuaJIT is not a phcc target in this recipe).
- `-DLUA_MATH_LIBRARY=/usr/lib/x86_64-linux-gnu/libm.so` is required
  because CMake's FindLua resolves `libm` only via the multiarch
  directory, which it finds through `CMAKE_LIBRARY_ARCHITECTURE` —
  a variable the TinyCC compiler-ABI probe leaves empty, so without
  the pre-seed the literal token `LUA_MATH_LIBRARY-NOTFOUND` leaks
  into the final link line and the link fails. The value mirrors
  exactly what the same probe resolves under GCC on this platform.

Receipts (2026-11-08, aletheia-core, master-based tree):

- **L1.5 — nlua0 byte-identity:** `libnlua0.so` built with gcc and
  with phcc; two real code generators (`gen_declarations.lua`,
  `gen_char_blob.lua`) plus a direct mpack/lpeg/bit probe produce
  byte-identical output (SHA-256) across the gcc, phcc-nlua0, and
  full-phcc configurations.
- **L2a — full `nvim` link under phcc: PASS.** With the one flag
  above, configure and build complete with no source changes.
  Binary: `build-phcc/bin/nvim`, NVIM v0.13.0-dev (master base), SHA-256
  `47f583b0eb9120b89027c3e4580800b7cc66c8fb40dddee0cbab608b8c4259ce`.
  Smoke: `--version`, headless Lua, API buffer creation, and a file
  round-trip all pass; the functional subset
  `test/functional/editor/count_spec.lua` passes 4/4.
- **L2b caveat (honest):** at the L2a rung the bundled dependencies
  (`.deps`, including libuv) are **gcc-built** and only *linked* by
  phcc; compiling libuv itself under phcc is still open. No claim is
  made that the whole dependency tree is phcc-compiled.

The phext runtime plugin in this patch is pure Lua and loads
identically under the phcc-built editor (cross-tested headlessly:
open / goto / edit / write / mutation control / no-op write identity
against an agi-scale phext).

## Honest limits (v1)

- No raw phext editing mode; no persistent empty scrolls; no scroll
  rename/move command (goto + yank + write + delete covers it).
- Undo is per scroll *visit*: returning to a scroll restores its edited
  content (held in session state), but its undo stack starts fresh.
  Undo never crosses a scroll boundary.
- The jumplist is exovim's: entries record buffer + line, so after a
  coordinate jump swaps the buffer's content, `<C-o>` restores the
  scroll's buffer position approximately (the plugin pushes `m'` on
  every jump and restores per-scroll cursor positions itself, but a
  dedicated phext history stack is v2).
- One buffer per file: no split view of two scrolls of the same file.
- Scroll text containing NUL bytes cannot be represented faithfully in
  an exovim buffer and is outside the editing model.
- `:PhextSearch` is O(file bytes) per invocation — the one legitimately
  linear operation, run on demand only.
- The help file is not yet listed in `runtime/doc/index.txt` (an
  upstream-owned file this patch deliberately does not touch; doc
  indexing is a follow-up — `:help phext.txt` works directly).

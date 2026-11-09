# PATCHES.md — this fork's divergence from upstream Neovim

This fork is upstream Neovim plus an auditable patch set. Every change
the fork carries is listed here, per file, with its reason. If it isn't
in this file, it isn't a fork change.

## Patch 1 — phext scroll navigation (runtime plugin)

- **Base:** upstream `master` at
  `dca26833799f7456a2518bb8cb46c417aff57a75`
  ("feat(connect)!: stop the old server #42770", 2026-11-09). The patch
  originally landed on c868e1ab (2026-11-08); on 2026-11-09 the fork's
  `master` was fast-forwarded to dca26833 and the branch rebased onto
  it (old tip preserved on
  `backup/emise-phext-support-20261109-pre-rebase`). At each base the
  fork's `master` and upstream `master` were the identical SHA
  (verified by fetch), so the patch bases on upstream directly.
- **Branch:** `emise/phext-support`.
- **Shape:** purely additive. **Zero existing upstream files are
  modified** — the whole patch set is new files. Replaying it onto a
  fresh upstream checkout is: add the files below, nothing else.
  (Since 2026-11-09, one exception forced by upstream's own CI: the
  news check requires a FEATURES entry for any feature PR, so the
  branch also adds a 5-line entry to `runtime/doc/news.txt` — the only
  upstream-file hunk in the set.)
- **Why no C, and why no `runtime/lua/vim/filetype.lua` entry:** upstream
  CONTRIBUTING asks that new functionality be implemented in Lua, and
  filetype *detection* parity with Vim is maintained upstream ("detection
  changes should be submitted to Vim first"). Detection therefore lives
  in the plugin itself (`BufReadCmd`/`BufNewFile` autocmds for
  `*.phext`), which keeps the patch at zero upstream-hot files at the
  cost of detection happening in a plugin instead of the filetype table.
  libphext (the reference Rust library) exposes no C ABI, so the
  delimiter walk is a vendored Lua port — an algorithm that already
  exists in three implementations (Rust, Python, this one) that agree
  byte-for-byte, verified by the corpus tests below.

### Files added

| file | lines | what it is and why |
|---|---|---|
| `PHEXT.md` | — | The phext-upgrade record: classification (A canonical format / B derived buffer+index / D undo+grammar+LSP), coordinate map, invariants, measured costs, honest limits. |
| `PATCHES.md` | — | This file. |
| `runtime/plugin/phext.lua` | 115 | Plugin entry: `g:loaded_phext` opt-out guard; autocmd detection for `*.phext` (the coordinator decision that keeps the patch additive); `BufWriteCmd` for `phext://*` buffer names; registers all `:Phext*` user commands. |
| `runtime/lua/nvim/phext/init.lua` | 794 | Session layer: scroll-as-buffer model (one buffer per file, content swapped per scroll), per-scroll edit capture, serialise-on-write with external-change refusal, buffer-local mappings (`gP`, `g1`–`g9`, `g]`/`g[`, `]]`/`[[`, `]P`/`[P`, `mP`/`'P`), command implementations, `coordinate()`/`status()` Lua API. |
| `runtime/lua/nvim/phext/coord.lua` | 254 | Coordinate parse/format/arithmetic: 1-based floor, **no upper cap** (libphext 0.4.0 removed the 999 cap — do not reintroduce), delimiter-break semantics, dimension stepping with reset-lower, full and trailing-arm partial parsing. Pure Lua, unit-tested outside Neovim. |
| `runtime/lua/nvim/phext/index.lua` | 291 | Sparse index: single-pass delimiter walk (faithful port of the reference walk; delimiter bytes from libphext-rs `phext.rs`: library 0x01, shelf 0x1F, series 0x1E, collection 0x1D, volume 0x1C, book 0x1A, chapter 0x19, section 0x18, scroll 0x17), occupied = span ≥ 1 byte, binary-search populated lookup, and the serialiser (verbatim gap splice around untouched scrolls; canonical gap breaks only where edits force them). |
| `runtime/lua/nvim/phext/navigate.lua` | 143 | Navigation decisions (pure logic): arithmetic step, next/prev populated, next/prev within a dimension (filtered binary search, prefix fixed — design §6.3), coordinate description for `:PhextCoord`. |
| `runtime/lua/nvim/phext/outline.lua` | 272 | The TOC outline buffer: one zoom arm at a time (Outer/Middle/Inner), populated nodes only, cached per (revision, arm, scope); `<CR>` descends/jumps, `>`/`<` zoom, `q` closes. |
| `runtime/lua/nvim/phext/search.lua` | 140 | `:PhextSearch` (all scrolls → quickfix, module = coordinate, buffer-local `<CR>` performs the coordinate+line jump) and `:PhextTitles` (first-line picker via `vim.ui.select`). |
| `runtime/ftplugin/phext.lua` | 19 | Scroll-buffer presentation: coordinate statusline segment (`require('nvim.phext').status()`), commentstring, `b:undo_ftplugin`. |
| `runtime/doc/phext.txt` | 236 | Help: concepts, commands, mappings, API, options, limits. Not yet added to `runtime/doc/index.txt` (upstream-owned; follow-up). |
| `test/functional/plugin/phext_spec.lua` | 230 | Functional tests in upstream busted style: open/session, no-op write identity, populated walk, gap skipping, partial goto, step semantics, mutation control, delete/create on save, trailing-newline matrix, search→quickfix, external-change refusal. |
| `test/functional/fixtures/phext/basic.phext` | 22 B | Fixture: `alpha\nline2` ⟨0x17⟩ `beta` ⟨0x18⟩ `gamma` (sha256 3d34ce18…). |
| `test/functional/fixtures/phext/gaps.phext` | 11 B | Fixture: gap at scroll 2 + trailing break (sha256 907b1136…). |
| `test/functional/fixtures/phext/newlines.phext` | 8 B | Fixture: trailing-newline matrix (sha256 438d9828…). |

### Development summary (what a future rebaser needs)

- Model: **scroll-as-buffer** (design decision, not negotiable in a
  rebase without revisiting the design): the on-disk byte stream is the
  only truth; buffers hold exactly one scroll's text; delimiters never
  enter a buffer. Whole-file-as-buffer was rejected on Neovim's own
  invariants (byte identity unrecoverable in a line-oriented buffer;
  delimiters would become user-editable).
- Two coordinator decisions shaped this slice: (1) detection via plugin
  autocmd, zero upstream files touched; (2) scroll-as-buffer as the
  primary model.
- Semantics ported from the proven editors (phext-lattice `Navigator`,
  Phext Notepad native core): dimension step resets lower dimensions;
  backward steps clamp at 1; populated motion is index binary search;
  outline shows one zoom arm at a time.
- `]P`/`[P` semantics: nearest occupied scroll in the step direction
  among coordinates sharing the prefix above the active dimension
  (filtered binary search, per the design's implementation note) — *not*
  group-start landing.
- Write refusal is a deliberate `error()` inside `BufWriteCmd` (aborts
  the write = E813 semantics). `vim.notify` at ERROR level also raises
  (it echoes with `err=true`), so all other error paths use a
  non-raising `nvim_echo` helper — do not "simplify" those back to
  `vim.notify(..., ERROR)`.
- Known rebase friction: the `runtime/doc/news.txt` FEATURES hunk is
  the only hunk in an upstream file; it sits at the top of the EDITOR
  section and may need re-anchoring when upstream edits that section.
  `runtime/doc/tags` is generated (`make doc` / `:helptags`), never
  hand-merged.
- CI notes (2026-11-09): the fork's lint job installs StyLua *latest*
  (2.6.0 at time of writing), whose formatting of `or`-continuation
  lines differs from 2.3.x — files formatted with an older StyLua fail
  the check; format with the latest. The `wasm` check (nvim.wasm
  build) fails identically on plain upstream master (dca26833) and on
  the pre-patch base — pre-existing upstream, not this patch.
- Squash note: this patch lands as several small commits on
  `emise/phext-support` during development; per the phext-upgrade
  process it is squashed to ONE commit before any upstream-facing PR,
  with this file carrying the full reasoning.
- phcc build: this fork builds under phcc with a single CMake
  pre-seed and no source changes; the full recipe, the L1.5
  byte-identical nlua0 receipt, the L2a PASS receipt, and the honest
  L2b caveat (deps gcc-built at that rung; libuv under phcc still
  open) live in PHEXT.md, section "Building this fork with phcc".

### Verification receipts (2026-11-08, Muse VM)

The functional spec above is written for the upstream test harness
(`make functionaltest` needs a built nvim). The identical assertions
were executed locally two ways, against the exact files in this patch:

1. **Plain Lua 5.1.5 unit/corpus harness** (coord/index/navigate are
   vim-free): 60 assertions passed, 0 failed — including canonical
   rebuild byte-identity on 13 real corpus phexts (agi.phext 7,294
   scrolls, CYOA 4,602,370 bytes, singular.phext, tasks.phext, …) and
   index agreement (coordinates + span lengths) with an independent
   Python delimiter walk on tasks.phext and agi.phext.
2. **Stock Neovim 0.11.4 (AppImage) headless harness** with
   `set rtp+=<this repo>/runtime`: 37 assertions passed, 0 failed —
   session open, no-op write identity (sha256), populated walk, partial
   goto, step + `g]`, marks, edit persistence, mutation control at agi
   scale (prefix/suffix bytes outside the edited span unchanged),
   delete/create on save, search→quickfix jump, TOC arm descent,
   external-change refusal.
3. **Perf at agi scale** (1,552,681 bytes / 7,294 scrolls, LuaJIT):
   open+index 37.8–45.6 ms (budget 100), goto 0.074–0.107 ms (budget 5),
   outline outer-arm build 22.0–25.6 ms (**budget 20 — missed, cached
   thereafter**; reported honestly in PHEXT.md).
4. All Lua files pass `stylua --check` with the repo's `.stylua.toml`.

### Follow-ups (not in this patch)

- Add `phext.txt` to `runtime/doc/index.txt` + regenerate tags.
- Squash to one commit and open the fork PR (Will's call); an upstream
  `neovim/neovim` PR is a separate, later decision.
- phcc compilation of Neovim is a property of the C tree, which this
  patch does not touch; the runtime plugin loads identically under a
  phcc-built nvim.

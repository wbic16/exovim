# PATCHES.md — exovim's divergence from upstream Neovim

**exovim** is a full fork of Neovim. This file is the fork's
constitution: every change exovim carries over its upstream base is
listed here, per file, with its reason. If it isn't in this file, it
isn't a fork change.

## Base (pinned)

- **Upstream:** `neovim/neovim`, branch `release-0.12`, head
  `a7ac6c466e4addf330c015c3fd622a3effd4e20f`
  ("refactor(autocmd.c): remove useless comparison (#42586)").
- **Release tag:** `v0.12.6` = `779c36969e31080503be2dfccbcc3f999e289606`
  (Nvim 0.12.6, published 2026-10-09).
- **Tag → branch-head delta: 3 commits** — the post-release version
  bump (`3e5980d2cd`, merged by `28a7660ebc`) and one refactor backport
  (`a7ac6c466e`). The fork pins the branch head (not the tag) so the
  0.12.7 backport stream can be tracked; the version bump's own
  version change is superseded by Patch 2 below.
- **Fork branch:** `exovim-0.12`. Fork line version: **0.12.6-exovim.1**
  (tag `exovim-0.12.6.1`).
- **History:** the phext patch set was first developed against
  upstream `master` (0.13.0-dev) in wbic16/neovim — PR #1 there
  (squashed commit `cf7eeb60`, rebased `fa4d0895d5`) plus its CI fix
  pass (`f8d5d4c689`, `1919525303`, and PATCHES-record commits
  `de2c34eee4`, `7b5147e2ec`), merged to the fork's `master` as
  `1c2b15dc` and since synced to `f72cfc2c`. On 2026-11-09 Will
  directed a full fork from the last release under the new project
  name **exovim**; this branch is that fork. The complete phext
  divergence was enumerated by diffing the fork's `master` against
  its upstream merge base (`0c4b90023dac`): 16 files, 2,868
  insertions, 0 deletions — and replayed here.

## Patch 1 — phext scroll navigation (runtime plugin)

- **Shape:** purely additive new files, plus exactly one hunk in one
  upstream file (`runtime/doc/news.txt`, below).
- **Why no C, and why no `runtime/lua/vim/filetype.lua` entry:**
  upstream CONTRIBUTING asks that new functionality be implemented in
  Lua, and filetype *detection* parity with Vim is maintained
  upstream ("detection changes should be submitted to Vim first").
  Detection therefore lives in the plugin itself
  (`BufReadCmd`/`BufNewFile` autocmds for `*.phext`), keeping the
  patch at zero upstream-hot C/filetype files. libphext (the
  reference Rust library) exposes no C ABI, so the delimiter walk is
  a vendored Lua port — an algorithm that already exists in three
  implementations (Rust, Python, this one) that agree byte-for-byte,
  verified by the corpus tests below.

### Files added

| file | lines | what it is and why |
|---|---|---|
| `PHEXT.md` | — | The phext-upgrade record: classification (A canonical format / B derived buffer+index / D undo+grammar+LSP), coordinate map, invariants, measured costs, honest limits, phcc build recipe. |
| `PATCHES.md` | — | This file. |
| `runtime/plugin/phext.lua` | 115 | Plugin entry: `g:loaded_phext` opt-out guard; autocmd detection for `*.phext`; `BufWriteCmd` for `phext://*` buffer names; registers all `:Phext*` user commands. |
| `runtime/lua/nvim/phext/init.lua` | 794 | Session layer: scroll-as-buffer model (one buffer per file, content swapped per scroll), per-scroll edit capture, serialise-on-write with external-change refusal, buffer-local mappings (`gP`, `g1`–`g9`, `g]`/`g[`, `]]`/`[[`, `]P`/`[P`, `mP`/`'P`), command implementations, `coordinate()`/`status()` Lua API. |
| `runtime/lua/nvim/phext/coord.lua` | 254 | Coordinate parse/format/arithmetic: 1-based floor, **no upper cap** (libphext 0.4.0 removed the 999 cap — do not reintroduce), delimiter-break semantics, dimension stepping with reset-lower, full and trailing-arm partial parsing. Pure Lua, unit-tested outside Neovim. |
| `runtime/lua/nvim/phext/index.lua` | 291 | Sparse index: single-pass delimiter walk (delimiter bytes from libphext-rs `phext.rs`: library 0x01, shelf 0x1F, series 0x1E, collection 0x1D, volume 0x1C, book 0x1A, chapter 0x19, section 0x18, scroll 0x17), occupied = span ≥ 1 byte, binary-search populated lookup, and the serialiser (verbatim gap splice around untouched scrolls; canonical gap breaks only where edits force them). |
| `runtime/lua/nvim/phext/navigate.lua` | 143 | Navigation decisions (pure logic): arithmetic step, next/prev populated, next/prev within a dimension (filtered binary search, prefix fixed), coordinate description for `:PhextCoord`. |
| `runtime/lua/nvim/phext/outline.lua` | 272 | The TOC outline buffer: one zoom arm at a time (Outer/Middle/Inner), populated nodes only, cached per (revision, arm, scope); `<CR>` descends/jumps, `>`/`<` zoom, `q` closes. |
| `runtime/lua/nvim/phext/search.lua` | 140 | `:PhextSearch` (all scrolls → quickfix, module = coordinate) and `:PhextTitles` (first-line picker via `vim.ui.select`). |
| `runtime/ftplugin/phext.lua` | 19 | Scroll-buffer presentation: coordinate statusline segment, commentstring, `b:undo_ftplugin`. |
| `runtime/doc/phext.txt` | 238 | Help: concepts, commands, mappings, API, options, limits. Not yet added to `runtime/doc/index.txt` (upstream-owned; follow-up). Line count includes the fix-pass lintdoc corrections. |
| `test/functional/plugin/phext_spec.lua` | 230 | Functional tests in upstream busted style, including the fix-pass vararg-scope correction so the spec runs under the real functional harness. Release-base adaptation: uses the busted globals (`describe`/`it`/`before_each`) — master's `test.testutil` re-exports them (`t.describe`), the 0.12 base's does not, and the master form fails at load on this base (`attempt to call local 'describe' (a nil value)`, found by the 0.12 functional run). |
| `test/functional/fixtures/phext/basic.phext` | 22 B | Fixture: `alpha\nline2` ⟨0x17⟩ `beta` ⟨0x18⟩ `gamma` (sha256 3d34ce18…). |
| `test/functional/fixtures/phext/gaps.phext` | 11 B | Fixture: gap at scroll 2 + trailing break (sha256 907b1136…). |
| `test/functional/fixtures/phext/newlines.phext` | 8 B | Fixture: trailing-newline matrix (sha256 438d9828…). |

### Upstream file modified

| file | change | why |
|---|---|---|
| `runtime/doc/news.txt` | +6 lines: the phext FEATURES bullet at the top of the first EDITOR section | Upstream's news check requires a FEATURES entry for any feature change (the fix pass added the identical entry on master). On this release base the entry is re-anchored to the 0.12 changes' EDITOR section; wording is unchanged. This is the only upstream-file hunk in Patch 1. On a rebase, re-anchor it — never hand-merge `runtime/doc/tags` (generated). |

### Development summary (what a future rebaser needs)

- Model: **scroll-as-buffer** (design decision): the on-disk byte
  stream is the only truth; buffers hold exactly one scroll's text;
  delimiters never enter a buffer. Whole-file-as-buffer was rejected
  on Neovim's own invariants (byte identity unrecoverable in a
  line-oriented buffer; delimiters would become user-editable).
- Semantics ported from the proven editors (phext-lattice
  `Navigator`, Phext Notepad native core): dimension step resets
  lower dimensions; backward steps clamp at 1; populated motion is
  index binary search; outline shows one zoom arm at a time.
- `]P`/`[P` semantics: nearest occupied scroll in the step direction
  among coordinates sharing the prefix above the active dimension
  (filtered binary search) — *not* group-start landing.
- Write refusal is a deliberate `error()` inside `BufWriteCmd`
  (E813 semantics). `vim.notify` at ERROR level also raises, so all
  other error paths use a non-raising `nvim_echo` helper — do not
  "simplify" those back to `vim.notify(..., ERROR)`.
- Fix-pass lessons carried from master (2026-11-09): the functional
  spec's vararg-scope bug accounted for 11 of 13 original red CI
  checks; CI lint is StyLua *latest* (2.6.x formatting differs from
  2.3.x — format with latest); emmylua annotations and lintdoc
  (valid tag links, spelling, h1 title) are part of the patch, in
  the files above. The Windows functional job once exited 1 with
  490 passed / 0 failed on a byte-identical tree (harness-level
  flake) — recorded so a repeat is recognised, not re-debugged.
- CI note from master: the `wasm` check failed identically on plain
  upstream master and on the pre-patch base — pre-existing upstream,
  not this patch.

## Patch 2 — exovim distribution rename

The rename is deliberately **distribution-layer only**. Internals
remain Neovim's: the `nvim` binary target, `share/nvim`, stdpaths /
config dirs (`~/.config/nvim`), `NVIM_*` environment variables, and
the `vim` API are unchanged, so the Neovim plugin ecosystem works
unmodified. The binary ships *as* `exovim` via install prefix +
symlink (`/opt/exovim`, `/usr/local/bin/exovim` — see README.md),
which needs no source change at all.

| file | change | why |
|---|---|---|
| `CMakeLists.txt` | `NVIM_VERSION_PATCH` 7 → 6; `NVIM_VERSION_PRERELEASE` `"-dev"` → `"-exovim.1"` | The branch head carries upstream's post-release 0.12.7-dev bump; the fork's line is the 0.12.6 release plus exovim, so `--version` reports `NVIM v0.12.6-exovim.1`. Uses upstream's own version mechanism (the PRERELEASE field marked "for package maintainers"); no other build change. |
| `README.md` | Banner section prepended (project name, what phext adds, exovim install, compatibility note); upstream README body intact below | Discoverability: the fork's identity and install are visible from the surface a visitor lands on. |

## Verification receipts

Master-era receipts (2026-11-08, Muse VM + aletheia-core) are in
this file's history on the fork's `master` branch and summarised in
PHEXT.md: plain-Lua corpus harness 60/60, stock-nvim 0.11.4 headless
integration 37/37, phcc L1.5 nlua0 byte-identity and L2a full-build
PASS on the 0.13.0-dev tree.

Release-base receipts (2026-11-09) are appended here once the
exovim-0.12 build + test pass completes; nothing below this line is
claimed until it is measured on this base.

## Follow-ups (not in these patches)

- Add `phext.txt` to `runtime/doc/index.txt` + regenerate tags.
- An upstream `neovim/neovim` PR is a separate, later decision
  (Will's); this fork does not depend on it.
- phcc compilation of the bundled deps (libuv last) remains open
  (the L2b caveat in PHEXT.md).

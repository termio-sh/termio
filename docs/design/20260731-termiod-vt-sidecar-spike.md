# termiod authoritative-VT sidecar spike (#181)

Date: 2026-07-31
Status: de-risking result; this is not a v1 implementation

## Decision

**Phase 0 update:** §C.6 subsequently selected `libghostty-vt` for host/client
fidelity parity, overriding this spike's initial build-convenience preference
for `alacritty_terminal`. The standalone FFI gate passed; see §6. Keep the
packed 16-byte protocol cell owned and versioned by termiod, not by the VT
engine.

`libghostty-vt` has the stronger fidelity story and its C API can produce both
the `S` snapshot and the dirty-row input for `G`. It is not the zero-cost fit
assumed by §C.6, however:

1. the inspected 1.3.2 API does not expose a packed viewport whose C cell can
   double as termiod's 16-byte wire cell; and
2. every source build, including the CMake route and Linux-musl cross builds,
   requires Zig 0.15.2.

The Rust-native proof builds today with Cargo and the already-installed Rust
musl target, including a statically linked AArch64 Linux executable. That
removes a release/CI toolchain from the v1 critical path without coupling the
protocol to Alacritty's in-memory `Cell` layout.

## Scope and inspected inputs

The spike did not change the daemon, session fan-out, protocol, or hot path.
The executable under `termiod/spike/vt-sidecar/` is a standalone feasibility
artifact.

The Ghostty inspection used the complete vendored tree at
`/private/tmp/herdr-inspect/vendor/libghostty-vt/`. Its
`../libghostty-vt.vendor.json` pins Ghostty commit
`c5a21edfcbc2d5b46540ad91b7980aca31f5f1f3` and names the archive
`libghostty-vt-1.3.2-HEAD-+c5a21edfc.tar.gz`. The local upstream checkout at
`~/Documents/GitHub/ghostty` was used for `nix/libghostty-vt.nix`. The C API is
explicitly still signature-unstable even though the implementation is mature;
the [upstream Ghostty overview](https://github.com/ghostty-org/ghostty#cross-platform-libghostty-for-embeddable-terminals)
says the functionality is stable but API signatures remain in flux.

## 1. What the libghostty-vt C API actually exposes

### `include/ghostty.h` is not the VT API

Read literally, the requested
`/private/tmp/herdr-inspect/vendor/libghostty-vt/include/ghostty.h` does **not**
expose what the sidecar needs. Its opening comment calls it the Ghostty
embedding API and says it is not a general-purpose embedding API yet
(`include/ghostty.h:1-4`). It exposes opaque app/surface handles such as
`ghostty_surface_new` (`:1103`), `ghostty_surface_set_size` (`:1117`), and
`ghostty_surface_read_text` (`:1161`). It has no `ghostty_terminal_new`, raw VT
feed, grid traversal, or damage API.

The standalone VT umbrella is instead `include/ghostty/vt.h`, which includes
the split headers under `include/ghostty/vt/`. Against that API, the answer is
**yes: it has all semantic inputs needed for `S` and dirty-row `G`**, with a
conversion step into termiod's wire cells.

### Terminal lifecycle, feed, resize, dimensions, and cursor

| Need | Exact C API in the inspected vendor tree | Result |
| --- | --- | --- |
| Create/free | `GhosttyTerminalOptions { cols, rows, max_scrollback }` in `include/ghostty/vt/terminal.h:174-193`; `ghostty_terminal_new` at `:1213`; `ghostty_terminal_free` at `:1227` | Sufficient |
| Feed raw PTY bytes | `ghostty_terminal_vt_write(GhosttyTerminal, const uint8_t *, size_t)` in `terminal.h:1314` | Sufficient; the header explicitly says it feeds raw bytes through the VT parser |
| Resize | `ghostty_terminal_resize(... cols, rows, cell_width_px, cell_height_px)` in `terminal.h:1263` | Sufficient; primary-screen resize reflows and alternate-screen resize does not |
| Dimensions/cursor | `ghostty_terminal_get` at `terminal.h:1442` with `GHOSTTY_TERMINAL_DATA_COLS`, `ROWS`, `CURSOR_X`, and `CURSOR_Y` at `:910-938` | Sufficient |
| Active screen | `GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN` at `terminal.h:945` | Sufficient for primary/alternate state |

There is also `ghostty_terminal_grid_ref` (`terminal.h:1505`) plus
`ghostty_grid_ref_cell`, `_row`, `_graphemes`, and `_style`
(`include/ghostty/vt/grid_ref.h:124,137,162,203`). That is useful for point
queries, but `grid_ref.h:27-29` explicitly says not to build a render loop on
it; snapshots should use render state.

### Viewport cells, styles, cursor, and damage

`include/ghostty/vt/render.h:16-73` describes a stateful visible-viewport copy
optimized for repeated updates and dirty regions. A sidecar would:

1. create a `GhosttyRenderState` with `ghostty_render_state_new`
   (`render.h:325`);
2. refresh it with `ghostty_render_state_update` (`:360`), or minimize the
   terminal lock window with `ghostty_render_state_begin_update` / `_end_update`
   (`:392`, `:409`);
3. query columns, rows, global dirty state, row iterator, palette, cursor
   visibility/style, and viewport cursor coordinates via
   `ghostty_render_state_get` (`:425`) and `GhosttyRenderStateData`
   (`:134-203`); and
4. walk rows using `ghostty_render_state_row_iterator_new`, `_next`, and
   `ghostty_render_state_row_get` (`:508`, `:533`, `:551`), then walk cells
   using `ghostty_render_state_row_cells_new`, `_next`, and `_get`
   (`:623`, `:711`, `:747`).

The row query `GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY` is at `render.h:226`, and
the raw-screen alternative `GHOSTTY_ROW_DATA_DIRTY` is at
`include/ghostty/vt/screen.h:296`. Render state has a global tri-state
`GHOSTTY_RENDER_STATE_DIRTY_FALSE/PARTIAL/FULL` (`render.h:101-115`) and a dirty
flag per row. The caller must clear both levels after consuming them
(`render.h:55-70`). This directly supports the row selection for `G`.

For each visible cell, `GhosttyRenderStateRowCellsData` exposes:

- the opaque raw cell and complete `GhosttyStyle`;
- grapheme count/codepoints and direct UTF-8 encoding;
- resolved foreground and background RGB; and
- whether the cell has explicit styling.

Those selectors are in `render.h:632-702`. `GhosttyStyle` carries tagged
foreground/background/underline colors and bold, italic, faint, blink,
inverse, invisible, strike, overline, and underline state
(`include/ghostty/vt/style.h:82-108`). The lower-level cell API also exposes
codepoint/content/wide/style ID/background/semantic fields through
`GhosttyCellData` (`include/ghostty/vt/screen.h:105-208`). Together these are
enough to populate snapshot cells, dimensions, cursor, and dirty rows.

### Correction to the §C.6 cell-format assumption

The inspected ABI has no `ghostty_render_state_get_viewport` or equivalent
one-call packed-cell array. `GhosttyCell` and `GhosttyRow` are opaque 64-bit
values whose layouts must be queried (`screen.h:25-43`), while `GhosttyStyle`
is a separate sized struct. Render-state extraction is an iterator plus typed
queries.

Therefore the sentence in §C.6 that says “packed 16-byte cells ... one
snapshot call — the C struct doubles as the wire cell” is not true for this
libghostty-vt 1.3.2 ABI. Ghostty can produce `S` and identify rows for `G`, but
termiod must pack the results into its own stable 16-byte cell. A private C/Zig
shim could reduce FFI calls, but making a private Ghostty layout the protocol
would couple the wire ABI to an explicitly unstable library API and should be
rejected.

## 2. Linux-musl build and integration cost

### A source build requires Zig

There is no C-only or CMake-only compiler path:

- `build.zig.zon:6` requires Zig **0.15.2**.
- `build.zig:132-151` builds the static target and installs it as
  `libghostty-vt.a`.
- `CMakeLists.txt:94` performs `find_program(ZIG_EXECUTABLE zig REQUIRED)`, and
  its build rule at `:140` runs `zig build -Demit-lib-vt`.
- `dist/cmake/README.md:3-8` states directly that CMake wraps the Zig build and
  downstream projects still need Zig on `PATH`.
- The upstream Nix derivation at
  `~/Documents/GitHub/ghostty/nix/libghostty-vt.nix:56-85` places `zig_0_15` in
  `nativeBuildInputs` and passes `-Dcpu=baseline`, `-Dapp-runtime=none`, and
  `-Demit-lib-vt=true`; its `postInstall` moves `libghostty-vt.a` at `:96-99`.

The Zig build does support the desired target triples. It can produce
`x86_64-linux-musl` and `aarch64-linux-musl`, and the Linux/macOS static
archive bundles the vendored Highway and simdutf objects so the consumer only
links libc (`CMakeLists.txt:180-187`). That makes the **result** convenient to
link, but does not remove Zig from the build that creates it.

Exact cost to adopt the Ghostty path: vendor/pin the Ghostty source and its Zig
package cache, provision and cache Zig 0.15.2 in developer, CI, release, and
cross-build environments, run one Zig build per target/optimization/SIMD
configuration, maintain generated Rust bindings or a hand-written subset, and
then statically link the archive. Zig is absent on the spike machine and was
not installed.

### No prebuilt Linux artifact was supplied

The vendored `dist/` contains only:

- `dist/cmake/GhosttyZigCompiler.cmake`
- `dist/cmake/README.md`
- `dist/cmake/ghostty-vt-config.cmake.in`

A search of the vendored source and Herdr integration found no `.a`, `.so`,
`.dylib`, `.dll`, `.lib`, or `.wasm`. The manifest's `dist_archive` is the
source distribution name, not a binary distribution. There was consequently
no prebuilt artifact with which to make an honest no-Zig FFI proof.

### How Herdr builds it

Herdr uses Rust FFI, not cgo:

- `/private/tmp/herdr-inspect/build.rs:7-12` maps Rust GNU/musl targets to Zig
  triples, including both requested musl architectures.
- `build.rs:61-72` invokes `zig build -Demit-lib-vt`, supplies target,
  optimization, SIMD and version flags, and `build.rs:83-91` adds the resulting
  static archive to Cargo's linker inputs.
- `/private/tmp/herdr-inspect/src/ghostty/bindings.rs` is a 4,240-line checked-in
  bindgen surface. Its safe wrapper calls `ghostty_terminal_new`,
  `ghostty_terminal_vt_write`, and `ghostty_terminal_resize` at
  `src/ghostty/mod.rs:742-849`, and wraps render state/dirty rows/cells from
  `:2291-3118`.
- `/private/tmp/herdr-inspect/scripts/build_vendored_libghostty_vt.sh:14` is the
  same direct `zig build -Demit-lib-vt` path.

This proves the integration shape and musl target mapping, not a way around
the Zig requirement.

## 3. Rust-native candidates

### `alacritty_terminal` 0.26.0

This is a complete, mature terminal state engine extracted from the
[Alacritty terminal emulator](https://github.com/alacritty/alacritty), not
just an escape parser. The upstream application describes itself as beta but
is widely used; the library is Apache-2.0 and declares Rust 1.85. The relevant
crate APIs are:

- `vte::ansi::Processor::advance(&mut handler, bytes)` in `vte-0.15.0/src/ansi.rs:298`
  feeds streaming raw bytes into `Term`;
- `Term::grid`, `Term::renderable_content`, and `Term::resize` in
  `alacritty_terminal-0.26.0/src/term/mod.rs:637-655` expose viewport state and
  resize behavior;
- `RenderableContent.cursor` at `term/mod.rs:2393-2399`, or
  `Grid::cursor` at `grid/mod.rs:110-114`, exposes the cursor;
- `TermDamage::{Full, Partial}`, `LineDamageBounds { line, left, right }`,
  `Term::damage`, and `Term::reset_damage` at
  `term/mod.rs:137-204,458-490` provide damage since the last reset; and
- `Cell { c, fg, bg, flags, extra }` at `term/cell.rs:125-149` provides text,
  color, style flags, combining codepoints, underline color, and hyperlinks.

`TermDamage::Partial` is actually more precise than §C.6 requires because it
returns damaged column bounds per line; mapping it to dirty rows is trivial.
Alternate-screen state is represented by `TermMode::ALT_SCREEN`, and `Term`
maintains active and inactive grids.

Build simplicity is the main advantage. It is a normal crates.io dependency;
the proof cross-build used Cargo, the installed Rust target, and the existing
`rust-lld` configuration. It required no Zig, C compiler, generated bindings,
or target-specific native archive. The crate does include Unix PTY/event-loop
dependencies even though the proof only uses `Term`, so a future integration
should measure compile time and binary size rather than assume the dependency
is minimal.

Its cell is **not** the wire cell: it contains an `Arc`-backed optional extra
object and Rust enums/bitflags. As with Ghostty, termiod must explicitly map
codepoint/grapheme policy, RGB/palette/default colors, wide-cell markers, and
attributes into the 16-byte protocol representation. That explicit boundary
is a feature: the wire format remains stable if the engine changes.

### `termwiz` 0.23.3

`termwiz` is mature as a component of WezTerm, MIT-licensed, pure Rust, and
does not need Zig. It has useful pieces:

- streaming raw-byte parsing through `escape::parser::Parser::parse`, producing
  `escape::Action` (`termwiz-0.23.3/src/escape/parser/mod.rs:59-95` and
  `src/escape/mod.rs:28`);
- `Surface` grid/dimensions/cursor/resize/cells at
  `src/surface/mod.rs:105,196-265,488-511`; and
- a retained `Change` log with `Surface::get_changes` at
  `src/surface/mod.rs:526`, useful for synchronizing surfaces.

But `termwiz` alone is not a drop-in authoritative VT. The byte parser emits
semantic escape `Action`s, while `Surface::add_changes` accepts the distinct
rendering-oriented `surface::Change` type. The crate contains no complete
`Action`-to-terminal-state evaluator (including DEC private modes,
primary/alternate screens, scroll regions, saved cursors, and all resize
semantics). Its own crate docs say it is “subject to fairly wild sweeping
changes” (`src/lib.rs:7-8`). WezTerm's full terminal state lives above
`termwiz`; adopting that larger layer or implementing the evaluator would be
more integration work and risk than `alacritty_terminal`.

Its layout also does not align with §C.6: a 64-bit test asserts
`CellAttributes` is 16 bytes and `Cell` is 24 bytes
(`src/cell.rs:1072-1078`). `get_changes` is a replay/diff stream for mutations
applied to a `Surface`, not the dirty-row contract of a full VT fed directly
from PTY bytes.

### Comparison

| Criterion | libghostty-vt 1.3.2 | alacritty_terminal 0.26.0 | termwiz 0.23.3 alone |
| --- | --- | --- | --- |
| Raw bytes → authoritative terminal | Yes | Yes | No; parser and surface exist, full evaluator does not |
| Snapshot cells/cursor/dimensions | Yes, through render iterators | Yes, through grid/renderable content | Surface can expose these only after another layer applies VT actions |
| Dirty rows | Yes, global + per-row render dirty | Yes, full or per-line column bounds | Change log, not direct VT damage |
| Fidelity/maturity | Highest; Ghostty core, broad modern-sequence support | High; production Alacritty core, less feature-rich than Ghostty | Strong building blocks, incomplete for this use alone |
| 16-byte wire-cell identity | No in inspected ABI | No | No (`Cell` is 24 bytes) |
| Linux-musl build | Supported, but source build requires Zig 0.15.2 | Cargo/Rust-only proof passed | Rust-only, but full emulator integration unresolved |
| FFI/API risk | C ABI explicitly in flux; unsafe bindings | Rust semver/API churn | Rust API explicitly in flux plus missing evaluator |

## 4. Recommendation and sequencing

**Historical note:** §C.6 has superseded the engine choice in this section with
`libghostty-vt`. The engine-neutral sidecar, wire-cell ownership, bounded tap,
and conformance recommendations still apply.

The recommendation is Rust-native first, specifically `alacritty_terminal`,
with Ghostty retained as the fidelity benchmark and possible second engine.
This is not a claim that Alacritty emulates more accurately. It is a sequencing
decision based on the facts uncovered by the spike: both engines need a cell
conversion layer, while only Ghostty adds Zig and FFI to the release matrix.

Recommended sequence:

1. **Freeze termiod's engine-neutral snapshot model and 16-byte wire cell.**
   Define exact Unicode/grapheme, wide-cell, default/palette/RGB, attribute,
   and unknown-feature behavior. Correct §C.6 so it no longer promises a
   Ghostty C struct as the wire ABI.
2. **Introduce an asynchronous sidecar boundary.** Raw `D` delivery remains
   authoritative and never waits for parsing. A bounded copy/tap feeds the VT
   worker; attach/resize/resync asks that worker for a point-in-time `S`.
   Overload may make a snapshot temporarily unavailable, but may never stall
   PTY fan-out. This preserves the anti-100× invariant.
3. **Implement v1 behind that boundary with `alacritty_terminal`.** Use its
   `TermDamage` only for the later opt-in `G` path. Build a conformance corpus
   covering alternate screen, resize/reflow, Unicode graphemes/wide cells,
   SGR 16/256/RGB colors, scroll regions, cursor visibility/style, and OSC/DCS
   behavior before committing compatibility promises.
4. **Run a bounded Ghostty bake-off after v1 semantics are frozen.** Provision
   Zig 0.15.2 explicitly, bind only the C symbols listed above, and compare
   snapshot/damage results and throughput against the same corpus. Switch the
   engine only if measured fidelity gaps justify the additional supply-chain,
   CI, FFI, and API-churn cost.

If exact Ghostty parity becomes a product requirement before step 3, selecting
libghostty-vt is technically feasible. The honest commitment is then “pin and
own Zig 0.15.2 plus a conversion ABI,” not “link a prebuilt C library whose
cells already match the wire.”

## 5. Standalone no-Zig proof

The proof is deliberately not a dependency of `termiod`:

- `termiod/spike/vt-sidecar/Cargo.toml` pins `alacritty_terminal = 0.26.0`;
- `termiod/spike/vt-sidecar/src/main.rs` creates a 12×4 terminal, feeds plain
  text and red SGR on the primary screen, enters `ESC[?1049h`, clears/homes the
  alternate screen, writes green SGR text, resizes to 16×5, writes blue text,
  then emits dimensions, cursor, active-screen state, dirty rows, one color
  sample, and the full grid; and
- no source file under `termiod/src/` was changed.

Native run:

```text
$ cd termiod
$ cargo run --manifest-path spike/vt-sidecar/Cargo.toml
engine=alacritty_terminal
dims=16x5
cursor=(4, 1)
alt_screen=true
dirty_rows=[1]
green_cell_fg=Named(Green)
grid:
00 |ALT GREEN       |
01 |blue            |
02 |                |
03 |                |
04 |                |
```

Cross-build:

```text
$ cargo build --manifest-path spike/vt-sidecar/Cargo.toml \
    --target aarch64-unknown-linux-musl
Finished `dev` profile ...

$ file spike/vt-sidecar/target/aarch64-unknown-linux-musl/debug/termiod-vt-sidecar-spike
ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked,
with debug_info, not stripped
```

This proves build, streaming feed, style retention, alternate-screen state,
resize, snapshot traversal, cursor/dimensions, and dirty-row extraction. It
does not prove the complete v1 protocol, snapshot packing, production load
isolation, or exhaustive VT conformance; those are intentionally outside this
de-risk spike.

## 6. Phase 0 libghostty-vt FFI build proof

Result: **passed**. The standalone crate at `termiod/spike/vt-ffi/` builds
vendored libghostty-vt, bindgens `include/ghostty/vt.h`, links its static
archive into Rust, runs the same snapshot scenario as §5, and cross-links a
static AArch64 Linux-musl executable. Nothing under `termiod/src/` depends on
the spike or changed for it.

### Toolchain installation

Zig was intentionally installed outside the repository and was not installed
with Homebrew:

- version: exactly `0.15.2`, enforced by `build.rs` before every Ghostty build;
- official archive:
  `https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz`;
- published and verified SHA-256:
  `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`;
- host-local install:
  `/Users/yuanjiwei/.local/share/termiod-toolchains/zig-0.15.2`; and
- `zig version` output: `0.15.2`.

The install directory is a machine-local toolchain and is not committed. Build
commands pass its executable through `ZIG`, so the crate neither relies on
Homebrew's current version nor silently accepts a different compiler.

One host SDK compatibility issue was found and resolved without installing
another SDK. Xcode 26.4's `libSystem.tbd` advertises `arm64e` rather than
`arm64`, causing Zig 0.15.2's build runner to report unresolved libc/dispatch
symbols. The already-installed Command Line Tools SDK 26.2 advertises
`arm64`; builds select it with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`. This environment
requirement is part of the reproduced command below.

### Vendoring and build shape

`termiod/spike/vt-ffi/vendor/libghostty-vt/` contains the build-relevant
libghostty-vt 1.3.2 source from the inspected Herdr distribution: `build.zig*`,
`src/`, `pkg/`, `include/`, `VERSION`, and `LICENSE`. The adjacent
`libghostty-vt.vendor.json` records source commit
`c5a21edfcbc2d5b46540ad91b7980aca31f5f1f3` and distribution
`1.3.2-HEAD-+c5a21edfc`.

The crate mirrors Herdr's integration pattern:

- `build.rs` maps Cargo targets to Zig targets, invokes
  `zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dcpu=baseline -Dsimd=true`,
  and links `libghostty-vt.a`;
- the Zig install prefix and cache live under Cargo's target-specific
  `OUT_DIR`, so native and cross archives do not overwrite each other;
- bindgen parses the vendored `include/ghostty/vt.h` and emits bindings into
  `OUT_DIR`; and
- on a cross build, bindgen deliberately parses the target-neutral public
  header using Cargo's Apple-aarch64 host target. Both targets have 64-bit
  `size_t`; this avoids requiring a separate musl C sysroot merely to find
  `stddef.h`, while Zig independently compiles the archive for Linux-musl.

Reproduced native command:

```text
$ cd termiod
$ DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  ZIG=/Users/yuanjiwei/.local/share/termiod-toolchains/zig-0.15.2/zig \
  LIBCLANG_PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/\
XcodeDefault.xctoolchain/usr/lib \
  cargo run --manifest-path spike/vt-ffi/Cargo.toml
```

Snapshot output, directly comparable with §5:

```text
engine=libghostty-vt
dims=16x5
cursor=(4, 1)
alt_screen=true
dirty_rows=[1]
green_cell_fg=rgb(181, 189, 104)
grid:
00 |ALT GREEN       |
01 |blue            |
02 |                |
03 |                |
04 |                |
```

This exercises `ghostty_terminal_new`, `ghostty_terminal_vt_write`,
`ghostty_terminal_resize`, dimension/cursor/active-screen getters,
`ghostty_render_state_update`, row/cell iteration, resolved foreground color,
and independent global/per-row dirty clearing. After clearing the baseline
damage and writing `blue`, Ghostty reports only row 1 dirty.

Cross-build and artifact:

```text
$ DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  ZIG=/Users/yuanjiwei/.local/share/termiod-toolchains/zig-0.15.2/zig \
  LIBCLANG_PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/\
XcodeDefault.xctoolchain/usr/lib \
  cargo build --manifest-path spike/vt-ffi/Cargo.toml \
    --target aarch64-unknown-linux-musl
Finished `dev` profile ...

$ file spike/vt-ffi/target/aarch64-unknown-linux-musl/debug/termiod-vt-ffi-spike
ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked,
with debug_info, not stripped
```

The unstripped Rust debug executable is 13 MiB. Its target-specific
ReleaseFast/SIMD libghostty-vt archive is 15 MiB. There is no remaining Phase 0
build blocker. Production integration still needs the engine-neutral wire-cell
conversion, a reviewed safe Rust wrapper, CI provisioning/cache policy for
Zig and libclang, and the bounded asynchronous sidecar tap; those remain out
of scope here.

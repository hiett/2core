# Unit 04 — `build_beam` driver & the compile/load FFI shim

> **One owner (small unit). Wave A — start immediately, depends on no freeze.** Pairs
> naturally with unit `03` (Core Erlang printer) but is fully independent of it: develop
> and test against **hand-written `.core` text**. Publishes the shared **«FFI-SHIM»**
> milestone on day 1.

## Context

This unit owns the **last seam in the backend**: turning Core Erlang *text* into a
loaded `.beam` module inside the running VM (decision **D10**). It sits after `08`
(`emit_core`, IR→Core AST) and `03` (`core_printer`, Core AST→`.core` text), but it does
**not** wait for them — you prove the compile+load mechanism with `.core` you write by
hand, *before* any codegen exists. Read [`00-overview.md`](00-overview.md) first; this
doc assumes D1–D10 and does not repeat them. Your output is what makes the rest of the
swarm's "did it actually run on the BEAM?" tests possible — `03`'s verification and every
end-to-end test in `08`/`10`/`11` runs generated modules through your shim.

## Goal

A single, measurable outcome: **given a binary of Core Erlang source text, produce a
loaded/loadable `.beam` module in the running VM and be able to `apply` its exports.**
Expose the **in-memory path as the default** and a **documented file fallback**, both
behind one stable `Result` contract. Prove it by compiling a hand-written `.core`
(identity + add + a `case`/guard), loading it, calling an export, and asserting the
numeric result — and prove that malformed `.core` yields a **typed `Error` with a human
message, never a crash**.

## Files owned

| Path | What |
|---|---|
| `src/twocore_codegen_ffi.erl` | The Erlang FFI shim: `compile_core/1` + `load_module/3`. **Deliver day 1** as «FFI-SHIM» — shared infra other units block on. Hand-written `.erl`, `twocore_`-prefixed module name (never collides with OTP). |
| `src/twocore/backend/build_beam.gleam` | The Gleam driver wrapping the shim: `compile_core`, `load_module`, optional `compile_and_load`, and the `BuildError` type. |
| `test/twocore/backend/build_beam_test.gleam` | Tests + hand-written `.core` fixtures. |

> **Naming hazard (overview §5, verified):** compiled/loaded module names share **one
> flat Erlang namespace with OTP**. The FFI module **must** be `twocore_codegen_ffi`
> (hand-written FFI → `twocore_` prefix); generated modules are `twocore@…`. Never name
> anything `lists`, `maps`, `erlang`, `compile`, … — a collision can stop the host app.

## Depends on

- **Nothing frozen.** No upstream freeze milestone gates this unit. You build and test
  entirely against `.core` text you author by hand.
- You will add one dependency: the `Atom` type comes from `gleam_erlang`
  (`import gleam/erlang/atom.{type Atom}`). Add `gleam_erlang` to `gleam.toml` and run
  `gleam deps download` — the scaffold only ships `gleam_stdlib` + `gleeunit`.
- **You unblock:** `03` (its printer needs a way to prove output compiles), and the e2e
  tests in `08`/`10`/`11`. Publish «FFI-SHIM» in `state.md` the moment `compile_core/1`
  scans/parses/compiles a trivial module.

## Scope — in / out for Phase 1

**In:**
- `compile_core` (text → `{Module, Beam}`) via the in-memory `core_scan`/`core_parse`/
  `compile:forms` path — see grounded facts.
- `load_module` (`code:load_binary/3` into the build/test VM — D10).
- Optional `compile_and_load` convenience.
- The documented **file fallback** (`compile:file`) behind the same `Result` contract.
- This stage's own `BuildError` type (D4).

**Out (Phase 1 — do not build):**
- Any code generation, IR, or Core Erlang AST (those are `08`/`03`).
- Loading into a **separate node/VM** — Phase 1 loads into the build/test VM (D10). A
  multi-tenant sandbox node is Phase 2 and explicitly **does not change this `Result`
  contract** (D10 note).
- Hot-reload policy, purge/old-code management, on-disk `.beam` caching.

## Deliverables

### 1. `src/twocore_codegen_ffi.erl` — the validated shim (copy this shape verbatim)

This shape is **VERIFIED on OTP 29**. Bake the scan→parse→forms pipeline in from day one
(see the pitfall below — retrofitting it later means rewriting the driver's error
handling).

```erlang
-module(twocore_codegen_ffi).
-export([compile_core/1, load_module/3]).

compile_core(CoreBin) when is_binary(CoreBin) ->
    Str = unicode:characters_to_list(CoreBin),
    case core_scan:string(Str) of
        {ok, Toks, _End} ->
            case core_parse:parse(Toks) of
                {ok, CMod} ->
                    case compile:forms(CMod, [from_core, binary, return_errors, return_warnings]) of
                        {ok, Mod, Beam, _W} -> {ok, {Mod, Beam}};
                        {ok, Mod, Beam}     -> {ok, {Mod, Beam}};
                        {error, Errs, _W}   -> {error, fmt_errs(Errs)}
                    end;
                {error, EI} -> {error, fmt_one(EI)}
            end;
        {error, EI, _End} -> {error, fmt_one(EI)}
    end.

fmt_errs(Errs) -> lists:flatten([[fmt_one(EI) || EI <- EIs] || {_F, EIs} <- Errs]).

fmt_one({Loc, Mod, Desc}) ->
    Msg = unicode:characters_to_binary(Mod:format_error(Desc)),
    <<(loc_bin(Loc))/binary, ": ", Msg/binary>>.

loc_bin({L, _C})              -> integer_to_binary(L);
loc_bin(L) when is_integer(L) -> integer_to_binary(L);
loc_bin(none)                 -> <<"module">>.

load_module(Mod, Filename, Beam) ->
    case code:load_binary(Mod, Filename, Beam) of
        {module, Mod}  -> {ok, Mod};
        {error, What}  -> {error, atom_to_binary(What, utf8)}
    end.
```

Note the two `{ok, …}` clauses for `compile:forms` — OTP returns the 4-tuple with
`return_warnings` and the 3-tuple without; handle both so a warning-free compile still
matches. `fmt_one` **normalizes** `core_parse`'s bare `{error,{Loc,Mod,Desc}}` and
`compile`'s nested `[{File,[{Loc,Mod,Desc}]}]` into the **same** flat `[Binary]` shape,
so the Gleam `Result` is stable regardless of which stage failed.

### 2. `src/twocore/backend/build_beam.gleam` — the Gleam driver

```gleam
import gleam/erlang/atom.{type Atom}
import gleam/result

/// This stage's own error type (D4 — there is no shared StageError).
pub type BuildError {
  /// Core Erlang scan, parse, or compile reported one or more diagnostics.
  /// Each string is a normalized "<loc>: <message>" line where <loc> is a line
  /// number or the literal "module". Messages are rendered via the failing
  /// module's `format_error/1` — never a raw term.
  CompileFailed(errors: List(String))
  /// `code:load_binary/3` rejected the binary (e.g. "sticky_directory",
  /// "badfile"). `reason` is the VM's error atom rendered as text.
  LoadFailed(reason: String)
}

@external(erlang, "twocore_codegen_ffi", "compile_core")
fn ffi_compile_core(core: BitArray) -> Result(#(Atom, BitArray), List(String))

@external(erlang, "twocore_codegen_ffi", "load_module")
fn ffi_load_module(module: Atom, filename: String, beam: BitArray) -> Result(Atom, String)

/// Compile Core Erlang source TEXT to an in-memory `.beam` binary.
///
/// `core_text` is UTF-8 `.core` source (byte-aligned — it is read as an Erlang
/// binary). Returns `Ok(#(module_name, beam_binary))` on success; the module name
/// is taken from the `.core` `module` header, NOT any filename. Returns
/// `Error(CompileFailed(lines))` if scan/parse/compile reports diagnostics. Does
/// not panic on malformed input — that is a tested property (D8).
pub fn compile_core(core_text: BitArray) -> Result(#(Atom, BitArray), BuildError) {
  ffi_compile_core(core_text)
  |> result.map_error(CompileFailed)
}

/// Load a `.beam` binary into the CURRENT VM (D10) and return its module name.
///
/// `module` must match the name baked into `beam`. `filename` is metadata only
/// (surfaced by `code:which`); it does not affect the loaded module's identity.
/// Returns `Ok(module)` or `Error(reason)` with the VM's rejection atom as text.
/// A name collision HOT-REPLACES an already-loaded module — namespace generated
/// modules `twocore@…` to avoid clobbering OTP or each other.
pub fn load_module(
  module: Atom,
  filename: String,
  beam: BitArray,
) -> Result(Atom, String) {
  ffi_load_module(module, filename, beam)
}

/// Convenience: compile text then load it, folding a load failure into BuildError.
/// Returns `Ok(module)` ready to `apply`, or the first failing stage's BuildError.
pub fn compile_and_load(core_text: BitArray) -> Result(Atom, BuildError) {
  use #(mod, beam) <- result.try(compile_core(core_text))
  load_module(mod, "twocore_generated", beam)
  |> result.map_error(LoadFailed)
}
```

**On `load_module`'s `Result(Atom, String)` (vs D4):** it is a deliberately thin
pass-through over `code:load_binary` exposing the raw VM reason. The **composed** stage
surface is `compile_and_load`, which returns `Result(Atom, BuildError)` and folds the
load reason into `LoadFailed` — so the stage's outward error type is still `BuildError`
(D4 honored), while granular callers can still read the raw atom.

### 3. The documented file fallback

Design `compile_core` so it can fall back to disk **without changing the `Result`
contract**. The fallback path: write `core_text` to a temp `mod.core`, then

```erlang
compile:file("…/mod", [from_core, binary, return_errors, return_warnings])
```

returns the identical `{ok,Mod,Beam,_W} | {ok,Mod,Beam} | {error,Errs,_W}` shape, so the
same `fmt_errs`/`fmt_one` normalization applies and the Gleam side is unchanged. Keep the
in-memory path the default; reach for the file path only if a future OTP quirk demands it.
Clean up the temp file in all branches.

## Grounded facts you MUST honor

These were **VERIFIED on OTP 29**. Honor them exactly; the call-outs are retrofit traps.

- **PITFALL — `compile:forms/2 + from_core` does NOT accept TEXT.** It expects **cerl
  records** (`#c_module{}`). Feeding it `.core` *text* crashes inside `core_lint`. The
  in-memory text path therefore MUST be:
  `core_scan:string/1` → `core_parse:parse/1` → `#c_module{}` →
  `compile:forms(CMod, [from_core, binary, return_errors, return_warnings])`.
  **Bake this into the shim from day one.** Retrofitting it later means rewriting the
  driver's error handling, because the error *shapes* differ per stage (next bullet).
- **PITFALL — error shapes differ and must be normalized in the shim.** `compile:*`
  errors are `[{File,[{Loc,Mod,Desc}]}]`; `core_parse:parse` returns a **bare**
  `{error,{Loc,Mod,Desc}}` (one less level of nesting); `core_scan:string` returns
  `{error, EI, End}`. Normalize **all three** into one flat `[Binary]` in the shim
  (`fmt_errs`/`fmt_one` above) so the Gleam `Result` is stable.
- **PITFALL — `Desc` is a TERM, not a string.** e.g. `{undefined_function,{missing,0}}`.
  Render it via `Mod:format_error(Desc)` — **never** string-concatenate a raw `Desc`.
- **PITFALL — location is one of three forms:** `{Line,Col}` | `Line` (integer) |
  `none`. Handle all three (`loc_bin/1` above maps `none` → `"module"`).
- **Gleam FFI mapping:** in `@external(erlang, "twocore_codegen_ffi", "compile_core")`
  the Erlang module name is **RAW (not Gleam-mangled)**. Erlang `{ok,X}`/`{error,E}` map
  directly onto Gleam `Result`. An Erlang 2-tuple `{Mod,Beam}` maps to `#(Atom, BitArray)`;
  a list of binaries maps to `List(String)`.
- **PITFALL — Gleam does NOT type-check FFI returns.** Treat `twocore_codegen_ffi.erl`
  as a **trust boundary**: validate the returned shapes in tests (assert `Ok` carries an
  atom + a non-empty binary; assert `Error` carries a non-empty `List(String)`).
- **`code:load_binary/3` loads into the CURRENT VM (D10).** The loaded module's name
  comes from the `.core` `module` header, **not** the filename. A name collision
  **hot-replaces** the loaded module — hence the `twocore@…` namespacing rule.
- **PITFALL — the textual `from_core` format is UNDOCUMENTED** and may change between
  OTP releases; `core_scan`/`core_parse` are compiler-internal modules. **Pin to OTP 29.**
  Note this in the file's module doc.
- **`is_binary` guard:** `compile_core/1` guards on `is_binary(CoreBin)`. A Gleam
  `BitArray` for `.core` text is always byte-aligned, so this holds; do not pass a
  non-byte-aligned bitstring.

## Verification — Definition of Done (D8)

Tests assert against **Core Erlang / the Erlang compiler's defined behavior and ordinary
integer arithmetic — not against whatever bytes the compiler emits** (no
change-detector tests). The canonical references: the **Core Erlang language
specification** (Core Erlang 1.0.3,
<https://www.it.uu.se/research/group/hipe/cerl/doc/core_erlang-1.0.3.pdf>) and the OTP
**compiler** application (<https://www.erlang.org/doc/apps/compiler/>). This unit is what
proves high-level **§9.2** (compiled output is *real, preemptible BEAM code*) and **D10**.

Required tests:

1. **Happy path, numeric assertion.** Hand-write a `.core` module with `id/1`, `add/2`,
   and a `classify/1` that uses a `case`/guard. Run it through `compile_core` →
   `load_module`, then `apply` an export and assert the **arithmetic result**:
   `add(2, 3) == 5`, `id(42) == 42`, `classify(0)`/`classify(7)` hit the expected guard
   arm. (5 is what `2 + 3` is — the spec being asserted is integer addition, not the
   compiler's byte output.) Call exports from the test via a raw external, e.g.
   `@external(erlang, "erlang", "apply") fn erl_apply(m: Atom, f: Atom, a: List(Int)) -> Int`.
2. **Malformed input → typed Error, no crash.** Feed syntactically broken `.core`
   (and separately, semantically broken — e.g. a call to an undefined function). Assert
   the result is `Error(CompileFailed(lines))` with `lines` non-empty and each line a
   human-readable `"<loc>: <message>"` — **assert it does not `panic`/throw** (fail-closed,
   D4). This locks the shim's error-normalization contract.
3. **FFI shape validation** (trust-boundary, since Gleam can't type-check the `.erl`):
   on success assert the returned module atom and a non-empty `beam` binary; on failure
   assert a non-empty `List(String)`.
4. **Round-trippable VM behavior:** load, `apply`, and confirm the module is actually
   resident (e.g. a second `compile_and_load` of a same-named module hot-replaces without
   error) — demonstrating real loaded BEAM code, not a static artifact.

Authoring the `.core` fixtures: hand-author for readability, but **cross-check validity by
generating a reference** with `erlc +to_core small.erl` (which emits canonical OTP-29
textual Core Erlang) — that is the authoritative shape your hand-written fixture must
match. Keep fixtures small and committed under `test/`.

Process gates (D8): `gleam build` has **no warnings**; `gleam format --check src test` is
clean; **every public function has a doc comment** stating contract / params / `Result`
semantics / failure modes. Update `state.md`: mark «FFI-SHIM» published and the unit's
"what it leaves" column.

## Concurrency

Small unit — most efficient as **one owner**. If split, the natural seam is:

- **Sub-task A — the `.erl` shim (`twocore_codegen_ffi`).** Self-contained; **deliver
  first** so it can be published as «FFI-SHIM» on day 1 and unblock `03`/`08`/`10`. Its
  only contract is the normalized return shapes — freeze those first.
- **Sub-task B — the Gleam driver + tests.** Targets the shim's frozen return shapes;
  can proceed against a stubbed shim. The `BuildError` type and the
  `compile_core`/`load_module`/`compile_and_load` signatures must be frozen before B and
  the e2e units consume them.

Nothing upstream must be frozen for either sub-task; the gating freeze is **internal** to
this unit (the shim's return shapes + the driver signatures above).

## What this leaves for others

- **«FFI-SHIM» published.** `03`'s printer verification can now compile its `.core` text
  and confirm it is accepted by the Erlang compiler.
- Every **end-to-end test** in `08` (emit_core), `10` (validate+lower), and the `11`
  capstone can compile generated `.core` to a `.beam` binary, `code:load_binary` it, and
  `apply` the export — i.e. actually *run* generated modules on the BEAM (D10).
- The **compile+load seam is proven before any codegen exists**, de-risking the longest
  poles (`08`, `10`) by removing "can it even load?" from their critical path.

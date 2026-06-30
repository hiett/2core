//// Tests for the `build_beam` driver + the «FFI-SHIM» (Unit 04).
////
//// These assert against the *defined behavior* of Core Erlang and the Erlang
//// compiler, and against ordinary integer arithmetic — NOT against whatever
//// bytes the compiler happens to emit (no change-detector tests, D8). `5` is
//// asserted for `add(2, 3)` because integer addition says so; the `.beam` byte
//// layout is never inspected.
////
//// Canonical references: the Core Erlang language specification (Core Erlang
//// 1.0.3) and the OTP `compiler` application docs. This unit is what proves
//// high-level §9.2 (compiled output is real, preemptible BEAM code) and D10
//// (it loads into and runs in the current VM).
////
//// The `.core` fixtures are hand-authored for readability and cross-checked
//// against the canonical OTP-29 shape emitted by `erlc +to_core`. They are
//// embedded as string constants (committed under `test/`), keeping the test
//// self-contained with no file-reading dependency.

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/string
import twocore/backend/build_beam.{CompileFailed}

// ───────────────────────── test-only externals ─────────────────────────
//
// Calling a loaded export from a Gleam test needs a raw `erlang:apply`. Gleam
// cannot type-check FFI returns, so we keep two narrowly-typed, private wrappers
// — one per result shape we assert (integer arithmetic vs. an atom guard arm).

/// `erlang:apply(Module, Function, Args)` for exports that return an integer.
@external(erlang, "erlang", "apply")
fn apply_int(module: Atom, function: Atom, args: List(Int)) -> Int

/// `erlang:apply(Module, Function, Args)` for exports that return an atom.
@external(erlang, "erlang", "apply")
fn apply_atom(module: Atom, function: Atom, args: List(Int)) -> Atom

// ───────────────────────────── fixtures ─────────────────────────────

/// A valid hand-written `.core` module: `id/1`, `add/2` (via `erlang:'+'`), and
/// `classify/1` (a `case` with two guards + a catch-all). Module name is
/// `twocore@test@fixture` — `twocore@…`-namespaced so it cannot clobber OTP.
const fixture_core: String = "module 'twocore@test@fixture' ['add'/2, 'classify'/1, 'id'/1]
    attributes []

'id'/1 =
    fun (X) -> X

'add'/2 =
    fun (A, B) ->
        call 'erlang':'+'(A, B)

'classify'/1 =
    fun (N) ->
        case N of
            <X> when call 'erlang':'=<'(X, 0) ->
                'zero_or_neg'
            <X> when call 'erlang':'<'(X, 10) ->
                'small'
            <_X> when 'true' ->
                'big'
        end
end
"

/// First version of a hot-swappable module `twocore@test@hotswap`: `val/0`
/// returns `1`. Loaded then replaced by `hotswap_v2_core` in the hot-replace
/// test to prove the loaded code is genuinely resident (D10), not a static
/// artifact.
const hotswap_v1_core: String = "module 'twocore@test@hotswap' ['val'/0]
    attributes []

'val'/0 =
    fun () -> 1
end
"

/// Second version of `twocore@test@hotswap`: `val/0` returns `2`. Same module
/// name as v1, so loading it hot-replaces v1.
const hotswap_v2_core: String = "module 'twocore@test@hotswap' ['val'/0]
    attributes []

'val'/0 =
    fun () -> 2
end
"

/// Syntactically broken `.core` (stray `@@@` tokens) — exercises the
/// `core_parse` error path.
const broken_syntax_core: String = "module 'twocore@test@broken' ['oops'/0]
    attributes []
'oops'/0 =
    fun () -> @@@ not valid @@@
"

/// Semantically broken `.core`: calls an undefined local function `missing/0`.
/// Scans and parses fine, but `compile:forms` rejects it — exercises the
/// `compile` error path (a different error shape than `core_parse`).
const broken_semantic_core: String = "module 'twocore@test@badsem' ['go'/0]
    attributes []
'go'/0 =
    fun () -> apply 'missing'/0 ()
end
"

/// Helper: `.core` source string → byte-aligned `BitArray` for `compile_core`.
fn core(src: String) -> BitArray {
  bit_array.from_string(src)
}

// ───────────────────── 1. happy path, numeric assertion ─────────────────────

/// Compiling, loading, and running the valid fixture must yield the spec-defined
/// arithmetic / guard results: `add(2,3) == 5`, `id(42) == 42`, and each
/// `classify` input lands in the documented guard arm. Proves the full
/// text → `.beam` → loaded → `apply` seam (D10, §9.2).
pub fn compile_load_run_happy_path_test() {
  let assert Ok(mod) = build_beam.compile_and_load(core(fixture_core))

  // The loaded module name comes from the `.core` `module` header.
  assert atom.to_string(mod) == "twocore@test@fixture"

  // add/2 is integer addition; 2 + 3 is 5.
  assert apply_int(mod, atom.create("add"), [2, 3]) == 5
  assert apply_int(mod, atom.create("add"), [-4, 4]) == 0
  // id/1 is the identity.
  assert apply_int(mod, atom.create("id"), [42]) == 42
  // classify/1 guard arms.
  let classify = atom.create("classify")
  assert apply_atom(mod, classify, [0]) == atom.create("zero_or_neg")
  assert apply_atom(mod, classify, [-5]) == atom.create("zero_or_neg")
  assert apply_atom(mod, classify, [7]) == atom.create("small")
  assert apply_atom(mod, classify, [9]) == atom.create("small")
  assert apply_atom(mod, classify, [10]) == atom.create("big")
  assert apply_atom(mod, classify, [100]) == atom.create("big")
}

// ───────────────── 2. malformed input → typed Error, no crash ─────────────────

/// Syntactically broken `.core` must produce `Error(CompileFailed(lines))` with
/// non-empty, human-readable `"<loc>: <message>"` lines — never a panic
/// (fail-closed, D4). The result is captured normally (no `let assert`), so a
/// panic would fail the test rather than be silently caught.
pub fn malformed_syntax_yields_typed_error_test() {
  let result = build_beam.compile_core(core(broken_syntax_core))

  let assert Error(CompileFailed(lines)) = result
  assert lines != []
  // Each line is a non-empty rendered diagnostic of the form "<loc>: <msg>".
  assert list.all(lines, fn(l) { l != "" && string.contains(l, ": ") })
}

/// Semantically broken `.core` (a call to an undefined function) scans and
/// parses but is rejected by `compile:forms`. It must ALSO surface as
/// `Error(CompileFailed(lines))` with non-empty lines — proving the shim
/// normalizes the (differently-shaped) `compile` errors into the same flat list
/// as the parse errors. No panic.
pub fn malformed_semantic_yields_typed_error_test() {
  let result = build_beam.compile_core(core(broken_semantic_core))

  let assert Error(CompileFailed(lines)) = result
  assert lines != []
  assert list.all(lines, fn(l) { l != "" })
}

// ───────────────────────── 3. FFI shape validation ─────────────────────────

/// Trust-boundary check (Gleam cannot type-check the `.erl` return): on success
/// `compile_core` must hand back the expected module atom AND a non-empty `beam`
/// binary.
pub fn ffi_success_shape_test() {
  let assert Ok(#(mod, beam)) = build_beam.compile_core(core(fixture_core))
  assert atom.to_string(mod) == "twocore@test@fixture"
  // A real `.beam` binary is non-empty.
  assert bit_array.byte_size(beam) > 0
}

/// Trust-boundary check: on failure `compile_core` must hand back a non-empty
/// `List(String)` (every element a non-empty string), regardless of which stage
/// failed.
pub fn ffi_failure_shape_test() {
  let assert Error(CompileFailed(lines)) =
    build_beam.compile_core(core(broken_syntax_core))
  assert lines != []
  assert list.all(lines, fn(l) { string.length(l) > 0 })
}

// ──────────────── 4. round-trippable VM behavior (hot-replace) ────────────────

/// Loading the same module name twice must succeed both times and the SECOND
/// load must hot-replace the first — demonstrating that the loaded module is
/// genuinely resident BEAM code, not a static artifact. After loading v1,
/// `val/0` returns `1`; after loading v2 (same module name), `val/0` returns
/// `2`. (Core Erlang / OTP code-loading semantics: `code:load_binary` replaces
/// current code with the new version.)
pub fn hot_replace_resident_module_test() {
  let val = atom.create("val")

  let assert Ok(mod1) = build_beam.compile_and_load(core(hotswap_v1_core))
  assert atom.to_string(mod1) == "twocore@test@hotswap"
  assert apply_int(mod1, val, []) == 1

  let assert Ok(mod2) = build_beam.compile_and_load(core(hotswap_v2_core))
  assert atom.to_string(mod2) == "twocore@test@hotswap"
  // The resident module was hot-replaced: the export now returns v2's value.
  assert apply_int(mod2, val, []) == 2
}

// ───────────────── split-surface: compile_core then load_module ─────────────────

/// `compile_core` and `load_module` compose: compiling separately, then loading
/// the returned binary under its own module atom, yields a callable module —
/// the same outcome as `compile_and_load`, but via the granular two-step API.
/// `load_module` returns the module atom on success.
pub fn split_compile_then_load_test() {
  let assert Ok(#(mod, beam)) = build_beam.compile_core(core(fixture_core))
  let assert Ok(loaded) = build_beam.load_module(mod, "fixture.core", beam)
  assert loaded == mod
  assert apply_int(loaded, atom.create("add"), [40, 2]) == 42
}

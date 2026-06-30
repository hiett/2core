//// Spec-grounded tests for `rt_state` (unit 03) — the per-instance cell holder.
////
//// Assertions target WebAssembly instantiation/global semantics and the unit's E1/E3
//// contracts, NOT whatever the implementation happens to emit:
////
//// - **Globals exec** — `global.get` returns the current value; `global.set` writes exactly
////   the named global (<https://webassembly.github.io/spec/core/exec/instructions.html>).
//// - **Floats are raw bits (D5)** — f32/f64 globals are stored/returned as the raw IEEE-754
////   bit pattern `Int`, bit-exact, never via a BEAM double
////   (<https://webassembly.github.io/spec/core/syntax/values.html#floating-point>).
//// - **Instantiation installs fresh state** — a (re)instantiation resets memory/table/globals
////   (<https://webassembly.github.io/spec/core/exec/modules.html#instantiation>); two
////   instantiations never observe each other's state (E1 isolation).
//// - **Fail-closed (E3)** — an op on an un-seeded cell raises rather than reading garbage.
////
//// Exceptions are caught via the namespace-hygienic `twocore_rt_state_test_ffi` helper
//// (pure Gleam cannot `catch`).

import gleam/dynamic
import gleam/result
import gleeunit/should
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{StateDecl}

/// Run `thunk` and report whether it raised: `Ok(value)` on a normal return, `Error(text)`
/// on any raise/exit/throw. The fail-closed tests assert `result.is_error` — i.e. the op
/// raised at all (E3: never read garbage). See `twocore_rt_state_test_ffi`.
@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

// ── 1. Global round-trip (global.set / global.get exec semantics) ──────────────

/// `seed`ing two globals then `global_set`/`global_get` round-trips the named global, and
/// a write to one global leaves the other untouched (global.set targets exactly one cell).
pub fn global_round_trip_test() {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 7), #("h", 100)],
    table: dynamic.nil(),
  ))

  // Initial inits are visible.
  rt_state.global_get("g") |> should.equal(7)
  rt_state.global_get("h") |> should.equal(100)

  // A write to g round-trips and does not disturb h.
  rt_state.global_set("g", 42)
  rt_state.global_get("g") |> should.equal(42)
  rt_state.global_get("h") |> should.equal(100)

  // A second write overwrites only the named global.
  rt_state.global_set("g", 43)
  rt_state.global_get("g") |> should.equal(43)
  rt_state.global_get("h") |> should.equal(100)
}

// ── 2. Float globals are bit-exact (D5: raw IEEE-754 bits, never a BEAM double) ─

/// f32/f64 globals carrying NaN-payload, `-0.0`, and `±Inf` bit patterns (as `Int`) survive
/// seed and `global_set`/`global_get` IDENTICALLY. A BEAM-double round-trip would mangle a
/// NaN payload / signalling bit or collapse `-0.0`; rt_state must store the `Int` verbatim.
pub fn float_globals_are_bit_exact_test() {
  // Raw bit patterns (as Int) for representative non-finite/edge floats.
  let f32_nan_payload = 0x7FC00001
  // quiet NaN, payload 1
  let f32_neg_zero = 0x80000000
  let f32_pos_inf = 0x7F800000
  let f32_neg_inf = 0xFF800000
  let f64_nan_payload = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  let f64_pos_inf = 0x7FF0000000000000

  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [
      #("f32_nan", f32_nan_payload),
      #("f32_nz", f32_neg_zero),
      #("f32_pinf", f32_pos_inf),
      #("f32_ninf", f32_neg_inf),
      #("f64_nan", f64_nan_payload),
      #("f64_nz", f64_neg_zero),
      #("f64_pinf", f64_pos_inf),
    ],
    table: dynamic.nil(),
  ))

  rt_state.global_get("f32_nan") |> should.equal(f32_nan_payload)
  rt_state.global_get("f32_nz") |> should.equal(f32_neg_zero)
  rt_state.global_get("f32_pinf") |> should.equal(f32_pos_inf)
  rt_state.global_get("f32_ninf") |> should.equal(f32_neg_inf)
  rt_state.global_get("f64_nan") |> should.equal(f64_nan_payload)
  rt_state.global_get("f64_nz") |> should.equal(f64_neg_zero)
  rt_state.global_get("f64_pinf") |> should.equal(f64_pos_inf)

  // A SET of a NaN payload is equally bit-exact (write path, not just the seed path).
  rt_state.global_set("f64_nz", f64_nan_payload)
  rt_state.global_get("f64_nz") |> should.equal(f64_nan_payload)
}

// ── 3. Fail-closed on an un-seeded cell (E3 — never read garbage) ──────────────

/// Without a `seed` (here forced via `clear`), every accessor RAISES rather than fabricating
/// a zeroed cell: `mem_get`/`table_get`/`global_get`/`global_set` all fail closed. (Reading
/// garbage out of an empty pdict is the bug this guard exists to prevent.)
pub fn fail_closed_on_unseeded_cell_test() {
  rt_state.clear()

  catch_thunk(fn() { rt_state.mem_get() })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.table_get() })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.global_get("g") })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.global_set("g", 0) })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.mem_put(dynamic.nil()) })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.table_put(dynamic.nil()) })
  |> result.is_error
  |> should.be_true
}

/// An accessor SUCCEEDS once the cell is seeded — the fail-closed guard is exactly the
/// un-seeded case, not a blanket refusal (proves test 3 is meaningful, not vacuous).
pub fn accessor_succeeds_once_seeded_test() {
  rt_state.clear()
  catch_thunk(fn() { rt_state.global_get("g") })
  |> result.is_error
  |> should.be_true

  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 5)],
    table: dynamic.nil(),
  ))
  catch_thunk(fn() { rt_state.global_get("g") })
  |> should.equal(Ok(5))
}

/// An undeclared global also fails closed even on a SEEDED cell (an internal invariant
/// violation, distinct from the un-seeded case — both are unreachable under validation).
pub fn fail_closed_on_undeclared_global_test() {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 1)],
    table: dynamic.nil(),
  ))
  catch_thunk(fn() { rt_state.global_get("does_not_exist") })
  |> result.is_error
  |> should.be_true
}

// ── 4. (Re)seed installs fresh state, discarding the prior cell ────────────────

/// A second `seed` RESETS the cell: none of the first instantiation's globals/mem/table
/// survive (WASM instantiation installs fresh state). `g` takes B's value, B's mem is in
/// place, and A-only globals are gone (read fails closed).
pub fn reseed_resets_prior_state_test() {
  let mem_a = dynamic.string("mem-A")
  let mem_b = dynamic.string("mem-B")

  rt_state.seed(StateDecl(
    mem: mem_a,
    globals: [#("g", 1), #("a_only", 111)],
    table: dynamic.nil(),
  ))
  rt_state.global_set("g", 1000)

  // Re-seed: fresh cell. Everything from A is discarded wholesale.
  rt_state.seed(StateDecl(
    mem: mem_b,
    globals: [#("g", 9)],
    table: dynamic.nil(),
  ))

  rt_state.global_get("g") |> should.equal(9)
  rt_state.mem_get() |> should.equal(mem_b)
  // A's `a_only` global did not survive the reset.
  catch_thunk(fn() { rt_state.global_get("a_only") })
  |> result.is_error
  |> should.be_true
}

// ── 5. Isolation across two seed cycles in one process (E1) ────────────────────

/// In ONE process, two instantiations never observe each other's globals. Seed cycle A sets
/// `g=1`; cycle B sets `g=2`; after B, `global_get("g")` is `2`, never `1`.
pub fn isolation_across_seed_cycles_test() {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 1)],
    table: dynamic.nil(),
  ))
  rt_state.global_get("g") |> should.equal(1)

  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 2)],
    table: dynamic.nil(),
  ))
  rt_state.global_get("g") |> should.equal(2)
}

// ── 6. The cell key is fixed & namespaced — no collision with rt_meter's fuel ──

/// Interleaving `rt_meter.charge` with `seed`/`global_set`/`global_get` proves the two pdict
/// cells live under DISTINCT keys: global ops never change the fuel total and `charge` never
/// changes a global (key hygiene / D3a — one fixed namespaced key per concern).
pub fn cell_key_does_not_collide_with_meter_fuel_test() {
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 5)],
    table: dynamic.nil(),
  ))

  rt_meter.charge(10)
  // A global write must not touch the fuel counter.
  rt_state.global_set("g", 99)
  rt_meter.fuel_consumed() |> should.equal(10)

  // A charge must not touch any global.
  rt_meter.charge(7)
  rt_state.global_get("g") |> should.equal(99)
  rt_meter.fuel_consumed() |> should.equal(17)

  // A re-seed (atomic reset of the whole cell) must not zero the fuel counter either.
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 1)],
    table: dynamic.nil(),
  ))
  rt_meter.fuel_consumed() |> should.equal(17)
}

// ── 7. Opaque field round-trip (rt_mem / rt_table own the value shapes) ────────

/// `mem_put`/`mem_get` (and `table_put`/`table_get`) round-trip an OPAQUE `Dynamic`
/// unchanged, `seed` installs the decl's mem/table, and writing one field leaves the other
/// (and the globals) intact. Sentinel `Dynamic`s stand in for 04/05's real shapes — rt_state
/// never inspects them.
pub fn opaque_field_round_trip_test() {
  let mem0 = dynamic.string("mem-0")
  let tbl0 = dynamic.list([dynamic.int(1), dynamic.int(2)])

  rt_state.seed(StateDecl(mem: mem0, globals: [#("g", 7)], table: tbl0))
  rt_state.mem_get() |> should.equal(mem0)
  rt_state.table_get() |> should.equal(tbl0)

  // Replace mem; table + globals are untouched.
  let mem1 = dynamic.int(123_456)
  rt_state.mem_put(mem1)
  rt_state.mem_get() |> should.equal(mem1)
  rt_state.table_get() |> should.equal(tbl0)
  rt_state.global_get("g") |> should.equal(7)

  // Replace table; mem + globals are untouched.
  let tbl1 = dynamic.string("tbl-1")
  rt_state.table_put(tbl1)
  rt_state.table_get() |> should.equal(tbl1)
  rt_state.mem_get() |> should.equal(mem1)
  rt_state.global_get("g") |> should.equal(7)
}

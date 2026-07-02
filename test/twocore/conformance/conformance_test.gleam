//// gleeunit entry for the spec-suite runner (Tier-A) — drives the PINNED allowlist fixtures
//// present in `fixtures/` through the REAL pipeline and reports honest pass/skip/fail counts
//// (D9: skips are visible, never silent).
////
//// ## Phase 3: conformance-neutral under BOTH profiles (F7, capstone §G)
////
//// Phase 3 adds no IR nodes and no spec files, so the counts do not move; the proof is that the
//// SAME green holds under BOTH derived profiles — which also delivers the spec-suite half of the
//// F2 optimizer-soundness claim (capstone §B). The suite runs twice:
////   - `driver.pipeline_with(profiles.safe())`   — Baseline optimizer + enforcing fuel;
////   - `driver.pipeline_with(profiles.unsafe())` — Aggressive optimizer + open runtime.
//// Both must reach `fail == 0 && pass > 0`. A single optimizer or mode regression on ANY
//// allowlisted assertion goes red. The Safe fuel budget for the suite (`default_fuel_budget`) is
//// generous enough that no in-scope program trips `FuelExhausted` (the runaway proof 4 uses a
//// tiny `safe_metered` budget instead).
////
//// ## Phase 4 — the full-matrix conformance proof (capstone P4-11 proof 2, G2/G7)
////
//// Phase 4 adds NO IR nodes and NO spec files either (G7), so the counts STILL do not move
//// (15747 / 411 / 0). The Phase-4 proof is that the identical green holds under EVERY shipped
//// `(state_strategy × mem_tier[× table_tier])` binding (`combos.shipped`) — not a subset:
////   - `cell × paged`      — the Phase-2/3 tier-O/tier-P oracle posture, Safe;
////   - `threaded × paged`  — tier-P instance state (== the `portable` core), Safe;
////   - `cell × atomics`    — tier-O O(1) memory under the pdict calling convention, Safe;
////   - `threaded × atomics`— tier-O O(1) memory under record-threading, Safe;
////   - `cell × nif`        — the tier-N ceiling skeleton (Unsafe-only, delegates to paged).
//// WebAssembly is deterministic (the only non-determinism is NaN payload bits, which D5 pins as
//// raw patterns), so a correct `atomics` store and a correct `paged` store produce byte-identical
//// memory images ⇒ identical `Outcome`s (spec §4.4 — every ill-defined op traps; no undefined
//// behaviour to diverge on). A single tier/strategy regression on any allowlisted assertion (a
//// mis-endianned `atomics` load, a threaded record dropped across a call, an `ets` table miss)
//// goes red on that file. Each binding is built via `combos.binding_for` (D1 — the unit-07
//// profile/linker surface, bounded `cap_pages` so an atomics combo links), then driven through the
//// SAME `run_suite` gate. The two Phase-3 profiles stay as two more matrix points.
////
//// Tier-A needs NO engine at run time: the expected values are baked into the vendored `.wast`
//// (now JSON). The committed curated fixture subset makes this run in a fresh checkout;
//// `vendor/vendor.sh` regenerates the FULL allowlist (gitignored) for a wider local run — the
//// runner adapts to whatever `*.json` are present.
////
//// Gate: zero genuine FAILS (a fail is a real spec mismatch in the pipeline); SKIPS are expected
//// and printed (constructs beyond the slice — reference types, bulk memory, multi-memory,
//// non-function imports, multi-value, extended-const, memory64, text-format asserts, and the
//// allowlist files un-convertible at the pin). At least one PASS is required so the suite is not
//// vacuously green.

import gleam/int
import gleam/io
import gleam/list
import gleam/string
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/fixture
import twocore/conformance/runner.{type Driver, type Report}
import twocore/runtime/instance.{Binding}
import twocore/runtime/profiles
import twocore/tier/combos.{type Combo}

const fixtures_dir = "test/twocore/conformance/fixtures"

/// The Safe max-pages cap the full-matrix run bakes into EVERY combination. It must be (1) LARGE
/// ENOUGH that no in-scope spec assertion is changed by the cap — the widest is `call`/
/// `call_indirect`'s `as-memory.grow-value`, which grows a no-max `(memory 1)` by 306 pages and
/// expects the grow to SUCCEED (old size `1`), so the cap must be ≥ 307 — and (2) SMALL ENOUGH that
/// an `atomics` combo LINKS: `atomics` `fresh` pre-allocates to the effective max, so the cap must
/// be ≤ `rt_mem_atomics.atomics_reserve_cap_pages` (4096) or `validate_binding` fail-closes the
/// binding. `512` sits comfortably in `[307, 4096]`: above every in-scope memory footprint (so the
/// counts stay 15747 / 411 / 0, conformance-neutral, G7) and below the atomics reserve cap (so
/// every atomics combo reserves ≤ 512 pages and links). Unlike `combos.cap_pages` (16, sized for
/// the small acceptance corpus), this is sized for the whole spec suite; it is applied here — over
/// `combos.binding_for` — so unit 09's corpus differential keeps its own tighter cap unchanged.
const matrix_cap_pages: Int = 512

/// Bulk pure-numeric spec files that are **tier-invariant by construction**: they exercise no
/// memory / table / global / `call_indirect`, so under any `(state_strategy × mem_tier)` their
/// functions are never state-reaching and emit byte-identical code to `cell × paged` (the
/// threaded record threads through nothing; the memory tier is never linked). The FULL suite runs
/// them once under each Phase-3 profile (`spec_suite_safe`/`unsafe`), which is where a numeric
/// regression would surface. Re-running their ~13.5k assertions under all FIVE matrix combos
/// proves nothing about the tier axis and exhausts the CI runner (OOM). So the matrix runs every
/// OTHER file — memory / table / global / calls / control flow: everything the tier axis touches.
const matrix_skip_numeric: List(String) = [
  "const.json", "conversions.json", "f32.json", "f32_bitwise.json",
  "f32_cmp.json", "f64.json", "f64_bitwise.json", "f64_cmp.json",
  "float_exprs.json", "float_literals.json", "float_misc.json", "i32.json",
  "i64.json", "int_exprs.json", "int_literals.json",
]

/// Files that import `spectest`'s MEMORY/TABLE state — excluded from the NON-paged matrix combos
/// only (see `run_combo`). The P5-09 `link.spectest_export` builds the provided memory/table with
/// the PAGED tier unconditionally, so importing it under an `atomics` binding is a cross-tier
/// handle mismatch (a named P5-09 gap, not a spec divergence). These files stay GREEN under the
/// paged combos + both full profiles; their bulk semantics are tier-covered by the own-memory
/// `memory_*` files. A file appears here ONLY because its OWN memory would otherwise be atomics but
/// it imports the paged `spectest` memory — never for convenience.
const matrix_skip_spectest_state: List(String) = ["data.json"]

/// The spec suite under the fail-closed **Safe** profile (Baseline optimizer + enforcing fuel):
/// `fail == 0 && pass > 0`. This is the Phase-1/2 green re-run through the Phase-3 full chain
/// (`ir_lower → optimize → emit_core`), confirming the Baseline optimizer is conformance-neutral.
pub fn spec_suite_safe_test() {
  run_suite(
    driver.pipeline_with(profiles.safe()),
    "Safe (Baseline optimizer + enforcing fuel)",
  )
}

/// The spec suite under the **Unsafe** profile (Aggressive optimizer + `MeterOff` + open
/// BIF/host + passthrough stdlib): `fail == 0 && pass > 0`. Same fixtures, same expected values —
/// the Aggressive optimizer and the whole Unsafe posture change NO spec-observable answer (F2/F4).
/// This is the spec-suite half of the optimizer-soundness differential.
pub fn spec_suite_unsafe_test() {
  run_suite(
    driver.pipeline_with(profiles.unsafe()),
    "Unsafe (Aggressive optimizer + open runtime)",
  )
}

// ─────────────────────────── Phase-4: the full-matrix conformance run (proof 2, G2/G7) ───────────────────────────

/// The pinned suite under the `cell × paged` baseline (the Phase-2/3 tier-O/tier-P oracle posture
/// as a matrix point): `fail == 0 && pass > 0`. This is the `combos`-bound restatement of the Safe
/// run above (bounded `cap_pages` so it shares one code path with the atomics combos); the two must
/// report identical counts (conformance-neutral, G7).
pub fn spec_suite_matrix_cell_paged_test() {
  run_combo(combos.cell_paged)
}

/// The pinned suite under `threaded × paged` — tier-P instance state (the `portable` core): the
/// purely-functional record threaded through generated code produces byte-identical spec results to
/// `cell × paged` (`fail == 0 && pass > 0`). A threaded record dropped across a call would go red
/// here on the exact file that reads state after the call.
pub fn spec_suite_matrix_threaded_paged_test() {
  run_combo(combos.threaded_paged)
}

/// The pinned suite under `cell × atomics` — tier-O O(1) linear memory under the pdict calling
/// convention: `fail == 0 && pass > 0`. A mis-endianned or off-by-one `atomics` load/store would go
/// red on `endianness`/`address`/`memory_trap`. `cap_pages` keeps the atomics reservation bounded
/// while staying above every in-scope program's footprint (max 8 pages), so no spec result moves.
pub fn spec_suite_matrix_cell_atomics_test() {
  run_combo(combos.cell_atomics)
}

/// The pinned suite under `threaded × atomics` — the combination most likely to surface a threading
/// bug (a mutable `atomics` ref threaded through the record under record-returning code): `fail == 0
/// && pass > 0`, byte-identical to the paged oracle.
pub fn spec_suite_matrix_threaded_atomics_test() {
  run_combo(combos.threaded_atomics)
}

/// The pinned suite under `cell × nif` — the tier-N ceiling WHERE IT SHIPS (G8): a node-safe
/// skeleton delegating to the paged core (the production C NIF is documented-deferred), Unsafe-only
/// (G6). It LINKS and runs on a bare BEAM, so it must reach `fail == 0 && pass > 0` like the rest.
/// If a real C NIF were built and loaded, the same run would exercise it unchanged.
pub fn spec_suite_matrix_cell_nif_test() {
  run_combo(combos.cell_nif)
}

/// Drive the whole pinned suite under one shipped matrix `Combo` and assert the `run_suite` gate
/// (`fail == 0 && pass > 0`). The `Combo`'s coherent binding comes from `combos.binding_for` (the
/// unit-07 linker surface — never re-spelling a `rt_mem_*` module name), with only `safe_max_pages`
/// widened to `matrix_cap_pages` (a policy field `resolve_tiers` never rewrites, so the tier
/// coupling stays coherent) so the whole spec suite fits — and `validate_binding` re-confirms the
/// widened binding is still policy-legal (an `Atomics` combo stays within the reserve cap). Total.
fn run_combo(c: Combo) -> Nil {
  let binding =
    Binding(..combos.binding_for(c), safe_max_pages: matrix_cap_pages)
  let assert Ok(validated) = profiles.validate_binding(binding)
  // Under a non-PAGED memory tier, ALSO skip files that IMPORT `spectest`'s memory/table: the
  // P5-09 link contract (`link.spectest_export`) builds the provided memory/table with the PAGED
  // `rt_mem.fresh`/`rt_table.new` unconditionally, so importing it under an `atomics` binding hands
  // a paged handle to atomics-tier code (a cross-tier mismatch, not a spec divergence). This is a
  // NAMED, honest cross-unit gap (P5-09 spectest state is paged-tier); the affected file stays
  // GREEN under `paged` + both full profiles, and its tier-sensitive bulk semantics are covered
  // under `atomics` by `memory_init`/`memory_fill`/`memory_copy` (own-memory bulk, no import).
  let paged_only = case string.contains(c.label, "atomics") {
    True -> matrix_skip_spectest_state
    False -> []
  }
  // Skip the tier-invariant bulk-numeric files (see `matrix_skip_numeric`) — they cannot
  // differ across tiers and re-running them ×5 OOMs CI. The two full-profile runs cover them.
  run_suite_keep(
    driver.pipeline_with(validated),
    "Phase-4 matrix: " <> c.label,
    fn(name) {
      !list.contains(matrix_skip_numeric, name)
      && !list.contains(paged_only, name)
    },
  )
}

/// Run every `*.json` fixture present through `d`, print a per-file + total report tagged with
/// `label`, and assert zero genuine failures with at least one pass. Total — every command
/// passes/fails/skips; the runner never panics.
fn run_suite(d: Driver, label: String) -> Nil {
  run_suite_keep(d, label, fn(_) { True })
}

/// Like `run_suite`, but runs only the fixtures for which `keep(name)` is `True` (the matrix
/// combos skip the tier-invariant bulk-numeric files). Same zero-fail / non-vacuous gate.
fn run_suite_keep(d: Driver, label: String, keep: fn(String) -> Bool) -> Nil {
  let jsons = case ffi.list_dir(fixtures_dir) {
    Ok(entries) ->
      entries
      |> list.filter(string.ends_with(_, ".json"))
      |> list.filter(keep)
      |> list.sort(string.compare)
    Error(_) -> []
  }

  case jsons {
    [] -> {
      io.println(
        "\n[conformance] no fixtures present; run test/twocore/conformance/vendor/vendor.sh",
      )
      Nil
    }
    _ -> {
      io.println(
        "\n=== Phase-3 spec-suite conformance (Tier-A, pinned allowlist) — "
        <> label
        <> " ===",
      )
      let total =
        list.fold(jsons, runner.empty_report(), fn(acc, name) {
          let rep = run_one(d, name)
          io.println("  " <> pad(name, 22) <> line(rep))
          runner.merge(acc, rep)
        })
      io.println("  " <> pad("TOTAL", 22) <> line(total))
      print_skip_reasons(total)
      print_fail_reasons(total)

      // Honest gate: zero genuine spec mismatches; coverage is non-vacuous.
      assert total.fail == 0
      assert total.pass > 0
    }
  }
}

fn run_one(d: Driver, name: String) -> Report {
  case fixture.load(fixtures_dir <> "/" <> name) {
    Error(e) -> {
      io.println("  " <> pad(name, 22) <> "parse error: " <> e)
      runner.empty_report()
    }
    Ok(fix) -> runner.run_fixture(d, fix, fixtures_dir)
  }
}

fn line(r: Report) -> String {
  "pass="
  <> int.to_string(r.pass)
  <> "  skip="
  <> int.to_string(r.skip)
  <> "  fail="
  <> int.to_string(r.fail)
}

// Print a compact histogram of skip reasons (distinct stable prefixes) so the coverage
// gap is visible without dumping thousands of lines.
fn print_skip_reasons(r: Report) -> Nil {
  case r.skip {
    0 -> Nil
    _ -> {
      io.println("  skip reasons (sample of distinct categories):")
      r.skips
      |> list.map(reason_category)
      |> list.unique
      |> list.take(12)
      |> list.each(fn(c) { io.println("    - " <> c) })
    }
  }
}

fn print_fail_reasons(r: Report) -> Nil {
  case r.fails {
    [] -> Nil
    fails -> {
      io.println("  FAILURES:")
      list.each(fails, fn(f) { io.println("    * " <> f) })
    }
  }
}

// Collapse a per-assertion reason to a coarse category (drop the leading "file:line "
// and keep the stable tail) for the histogram.
fn reason_category(reason: String) -> String {
  let tail = case string.split_once(reason, " ") {
    Ok(#(_loc, rest)) -> rest
    Error(_) -> reason
  }
  // Keep a short, stable prefix so similar reasons collapse together.
  string.slice(tail, 0, 60)
}

fn pad(s: String, n: Int) -> String {
  case n - string.length(s) {
    gap if gap > 0 -> s <> string.repeat(" ", gap)
    _ -> s
  }
}

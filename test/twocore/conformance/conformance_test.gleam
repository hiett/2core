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
import twocore/runtime/profiles

const fixtures_dir = "test/twocore/conformance/fixtures"

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

/// Run every `*.json` fixture present through `d`, print a per-file + total report tagged with
/// `label`, and assert zero genuine failures with at least one pass. Total — every command
/// passes/fails/skips; the runner never panics.
fn run_suite(d: Driver, label: String) -> Nil {
  let jsons = case ffi.list_dir(fixtures_dir) {
    Ok(entries) ->
      entries
      |> list.filter(string.ends_with(_, ".json"))
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

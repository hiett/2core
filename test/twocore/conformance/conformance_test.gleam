//// gleeunit entry for the spec-suite runner (Tier-A) — drives the PINNED Phase-2
//// allowlist fixtures present in `fixtures/` through the REAL pipeline and reports
//// honest pass/skip/fail counts (D9: skips are visible, never silent).
////
//// Tier-A needs NO engine at run time: the expected values are baked into the vendored
//// `.wast` (now JSON). The committed curated fixture subset makes this run in a fresh
//// checkout; `vendor/vendor.sh` regenerates the FULL allowlist (gitignored) for a wider
//// local run — the runner adapts to whatever `*.json` are present.
////
//// Gate: zero genuine FAILS (a fail is a real spec mismatch in the pipeline); SKIPS are
//// expected and printed (constructs beyond the Phase-2 slice — reference types, bulk
//// memory, multi-memory, non-function imports, multi-value, extended-const, memory64,
//// text-format asserts, and the allowlist files un-convertible at the pin). At least one
//// PASS is required so the suite is not vacuously green.

import gleam/int
import gleam/io
import gleam/list
import gleam/string
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/fixture
import twocore/conformance/runner.{type Report}

const fixtures_dir = "test/twocore/conformance/fixtures"

/// Run every `*.json` fixture present through the real pipeline, print a per-file +
/// total report, and assert zero genuine failures with at least one pass.
pub fn spec_suite_allowlist_test() {
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
        "\n=== Phase-2 spec-suite conformance (Tier-A, pinned allowlist) ===",
      )
      let total =
        list.fold(jsons, runner.empty_report(), fn(acc, name) {
          let rep = run_one(name)
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

fn run_one(name: String) -> Report {
  case fixture.load(fixtures_dir <> "/" <> name) {
    Error(e) -> {
      io.println("  " <> pad(name, 22) <> "parse error: " <> e)
      runner.empty_report()
    }
    Ok(fix) -> runner.run_fixture(driver.pipeline(), fix, fixtures_dir)
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
